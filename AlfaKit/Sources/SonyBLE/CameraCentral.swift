import CoreBluetooth
import Foundation
import SonyProtocol

/// The connection engine's "brain": an `actor` that owns the pure ``GeotagPolicyEngine`` state and a ``CameraLink``
/// (the CoreBluetooth "hands"). It consumes `LinkEvent`s in order, runs them through the policy, applies the resulting
/// actions as link commands, and republishes `Sendable` ``CameraEvent``s on ``events``.
///
/// The lifecycle is built from CoreBluetooth semantics (`docs/05-battery-strategy.md`) — **not** ported from
/// `Saschl/alpha-gps`, whose lifecycle reproduces the very standby drain this project fixes.
public actor CameraCentral {
    public let policy: ConnectionPolicy

    /// Republished, UI-facing event stream.
    public nonisolated let events: AsyncStream<CameraEvent>

    private var engine: GeotagPolicyEngine
    private let bondedStore: BondedCameraStore
    private var state = GeotagState()
    private var link: CameraLink?
    private var pushCount = 0
    private var lastEmittedConnection: CameraConnectionState = .idle

    // Time-sync preferences (mirrored from `GeotagSettings`). `syncTimeZone` gates the DD11 tz/dst block;
    // `syncClock` gates the best-effort CC13 clock write on connect.
    private var syncClock = true
    private var syncTimeZone = true

    private let eventContinuation: AsyncStream<CameraEvent>.Continuation
    private let linkEvents: AsyncStream<LinkEvent>
    private let linkEventContinuation: AsyncStream<LinkEvent>.Continuation
    private var consumeTask: Task<Void, Never>?

    public init(
        policy: ConnectionPolicy = .balanced,
        bondedStore: BondedCameraStore = UserDefaultsBondedCameraStore()
    ) {
        self.policy = policy
        self.bondedStore = bondedStore
        engine = GeotagPolicyEngine(config: policy)
        (events, eventContinuation) = AsyncStream.makeStream(of: CameraEvent.self)
        (linkEvents, linkEventContinuation) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    // MARK: - Public API

    /// Creates the CoreBluetooth manager and begins consuming link events. Idempotent.
    public func start() {
        guard link == nil else { return }
        let continuation = linkEventContinuation
        let newLink = CameraLink(
            restoreIdentifier: "me.congee.alfa.central",
            knownIdentifier: bondedStore.load()?.id, // re-adopt the remembered camera without a fresh scan
            onEvent: { continuation.yield($0) }
        )
        link = newLink

        let stream = linkEvents
        consumeTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
        newLink.activate()
    }

    /// Fully releases the CoreBluetooth link and stops event consumption.
    public func stop() {
        apply(engine.reduce(&state, .setEnabled(false)))
        link?.deactivate()
        link = nil
        consumeTask?.cancel()
        consumeTask = nil
    }

    public func setEnabled(_ enabled: Bool) {
        apply(engine.reduce(&state, .setEnabled(enabled)))
    }

    public func submitLocation(_ fix: LocationFix) {
        apply(engine.reduce(&state, .location(fix)))
    }

    /// The sanctioned, explicit trigger to leave back-off and re-establish the link (e.g. a "Sync now" button).
    public func requestSync() {
        apply(engine.reduce(&state, .syncRequested))
    }

    /// Applies new connection thresholds (update distance / interval) at runtime. Recreates the pure engine with the
    /// new config; connection state is untouched, so a threshold change never disturbs a live link.
    public func setPolicy(_ policy: ConnectionPolicy) {
        engine = GeotagPolicyEngine(config: policy)
    }

    /// Sets the time-sync preferences: `clock` gates the best-effort CC13 write on connect; `timeZone` gates the
    /// DD11 tz/dst block on each location push.
    public func setTimeSync(clock: Bool, timeZone: Bool) {
        syncClock = clock
        syncTimeZone = timeZone
    }

    /// Forgets the remembered camera: clears persistence and gracefully drops any live link so the engine returns to a
    /// clean state (the resulting disconnect backs the policy off). The next Sync/enable scans afresh.
    public func forgetCamera() {
        bondedStore.clear()
        link?.forget()
    }

    /// The remembered camera (id + name), if any — lets the UI show it while disconnected, as Alpha Remote does.
    public func rememberedCamera() -> RememberedCamera? {
        bondedStore.load()
    }

    // MARK: - Link event handling

    private func handle(_ event: LinkEvent) {
        switch event {
        case let .bluetoothAvailability(availability):
            // Surface the fine-grained availability to the onboarding/permissions UI, then feed the coarse
            // ready/not-ready bit to the pure reducer (its input is unchanged).
            eventContinuation.yield(.bluetoothAvailability(availability))
            apply(engine.reduce(&state, .bluetoothState(ready: availability == .ready)))

        case let .discovered(id, name, rssi, manufacturerData):
            let model = manufacturerData.flatMap { SonyAdvertisement(manufacturerData: $0)?.modelCode } ?? name
            eventContinuation.yield(.discovered(peripheralID: id, modelCode: model, rssi: rssi))

        case let .ready(id, name):
            // Remember this bonded, location-capable camera so a later launch retrieves it directly, no scan needed.
            bondedStore.save(RememberedCamera(id: id, name: name))
            eventContinuation.yield(.cameraIdentified(peripheralID: id, name: name))
            // Best-effort clock sync (beta): the link no-ops when CC13 is absent.
            if syncClock {
                let packet = SonyTimePacket(date: Date(), timeZone: .current)
                link?.writeTime(packet.encoded())
            }
            apply(engine.reduce(&state, .connected))

        case .connectFailed:
            apply(engine.reduce(&state, .connectFailed))

        case .disconnected:
            apply(engine.reduce(&state, .disconnected))

        case .wroteLocation:
            pushCount += 1
            eventContinuation.yield(.locationPushed(count: pushCount))

        case let .notify(characteristic, value):
            // CC05 is the camera's power/standby signal: a confirmed power-off proactively tears down the link and
            // backs off. (The DD01 location-enabled flag is still observed-only in Phase 1.)
            if characteristic == SonyGATT.Characteristic.cameraPowerState,
               CameraPowerState(cc05: value) == .off {
                apply(engine.reduce(&state, .cameraPoweredOff))
            }

        case let .failure(message):
            eventContinuation.yield(.failure(message))
        }
    }

    /// Emits a state change if the connection state moved, then performs each policy action as a link command.
    private func apply(_ actions: [GeotagAction]) {
        if state.connection != lastEmittedConnection {
            lastEmittedConnection = state.connection
            eventContinuation.yield(.stateChanged(state.connection))
        }
        for action in actions {
            switch action {
            case .beginDiscovery:
                link?.beginDiscovery()
            case .cancelDiscoveryAndDisconnect:
                link?.disconnect()
            case .backOff:
                link?.backOff()
            case let .pushLocation(fix):
                // `syncTimeZone` gates the tz/dst block (offset-5 flag): with it off, the shorter 91-byte packet is
                // sent (the UTC clock itself is protocol-mandatory in DD11 and always rides along).
                let packet = SonyLocationPacket(
                    latitude: fix.latitude,
                    longitude: fix.longitude,
                    date: fix.timestamp,
                    timeZone: syncTimeZone ? .current : nil
                )
                link?.writeLocation(packet.encoded())
            }
        }
    }
}
