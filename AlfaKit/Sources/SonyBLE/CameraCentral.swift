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
    // `syncClock` gates the best-effort CC13 clock write on connect; `useGPSTime` sources that write from the
    // GNSS fix's timestamp instead of the device clock.
    private var syncClock = true
    private var syncTimeZone = true
    private var useGPSTime = false
    // Most recent fix from the location pipeline — the "Use GPS time" clock source for the CC13 write.
    private var lastFix: LocationFix?
    // Set when a `.ready` wanted a GPS-time clock write but no fresh fix existed yet; the next submitted fix
    // carries a current timestamp and flushes the write (only while connected — never toward a standby camera).
    private var pendingGPSClockSync = false
    /// A fix older than this is unusable as a clock source — writing its timestamp would set the camera slow.
    private static let gpsClockFreshnessSeconds: TimeInterval = 10
    // Mirrored from `GeotagSettings.backgroundResume`: hold a standing connect on a dropped link for background
    // auto-resume. Stored here so it survives a `link` recreation (re-applied in `start()`).
    private var backgroundResume = false
    // Whether the app is in the foreground. Mirrored here (not just forwarded) so it survives a `link` recreation and,
    // crucially, so a value seeded *before* `start()` reaches the link the moment it is created — a background
    // state-restoration relaunch must never let the link default to "foreground" and try to scan (see `docs/05`).
    private var isForeground = true
    // Last "Cnct. while Power OFF" state read from an advertisement (`0x21` bit `0x80`), persisted with the bonded
    // camera. Informational these days (the decline gate it once fed is gone) — kept for diagnostics and store
    // compatibility.
    private var lastSeenConnectsWhilePoweredOff: Bool?

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
        let remembered = bondedStore.load()
        let newLink = CameraLink(
            restoreIdentifier: "me.congee.alfa.central",
            knownIdentifier: remembered?.id, // re-adopt the remembered camera without a fresh scan
            onEvent: { continuation.yield($0) }
        )
        link = newLink
        // Re-apply mirrored state across a link recreation — both enqueue on the link's serial queue ahead of
        // `activate()`, so the flags are live before the first CoreBluetooth callback (incl. `willRestoreState`).
        newLink.setBackgroundResume(backgroundResume)
        newLink.setForeground(isForeground)

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

    /// Reports app foreground/background transitions. Returning to the foreground retries from back-off; leaving it
    /// keeps a live link **and** any standing reconnect intent so geotagging resumes in the background too. The value
    /// is mirrored so it survives a `link` recreation and can be seeded before `start()` (background relaunch).
    public func setForeground(_ active: Bool) {
        isForeground = active
        link?.setForeground(active) // the link picks scan-and-gate (fg) vs standing-connect (bg) reconnects with this
        apply(engine.reduce(&state, .setForeground(active)))
    }

    public func submitLocation(_ fix: LocationFix) {
        lastFix = fix
        if pendingGPSClockSync, state.connection == .connected {
            pendingGPSClockSync = false
            writeClockSync(now: Date())
        }
        apply(engine.reduce(&state, .location(fix)))
    }

    /// The sanctioned, explicit trigger to leave back-off and re-establish the link (e.g. a "Sync now" button).
    public func requestSync() {
        apply(engine.reduce(&state, .syncRequested))
    }

    /// Keep-alive tick, driven by the coordinator's heartbeat timer while connected: re-sends the last pushed position
    /// (restamped) so the camera never expires its location. A clean no-op unless connected with a prior push — it
    /// never issues a write that could wake a standby camera.
    public func heartbeat() {
        apply(engine.reduce(&state, .heartbeat(now: Date())))
    }

    /// Applies new connection thresholds (update distance / interval) at runtime. Recreates the pure engine with the
    /// new config; connection state is untouched, so a threshold change never disturbs a live link.
    public func setPolicy(_ policy: ConnectionPolicy) {
        engine = GeotagPolicyEngine(config: policy)
    }

    /// Sets the time-sync preferences: `clock` gates the best-effort CC13 write on connect; `timeZone` gates the
    /// DD11 tz/dst block on each location push; `gpsTime` sources the CC13 clock from the latest GNSS fix's
    /// timestamp instead of the device clock.
    public func setTimeSync(clock: Bool, timeZone: Bool, gpsTime: Bool) {
        syncClock = clock
        syncTimeZone = timeZone
        useGPSTime = gpsTime
    }

    /// Toggles background auto-resume (a standing connect on a dropped link vs. the conservative scan-and-gate). See
    /// ``GeotagSettings/backgroundResume``. Applies to the *next* dropped link; a live link is untouched.
    public func setBackgroundResume(_ enabled: Bool) {
        backgroundResume = enabled
        link?.setBackgroundResume(enabled)
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
            let advertisement = manufacturerData.flatMap { SonyAdvertisement(manufacturerData: $0) }
            // Remember whether this camera stays connectable while off, so it can be persisted for the safety gate.
            if let cwpo = advertisement?.connectsWhilePoweredOff { lastSeenConnectsWhilePoweredOff = cwpo }
            let model = advertisement?.modelCode ?? name
            eventContinuation.yield(.discovered(peripheralID: id, modelCode: model, rssi: rssi))

        case let .ready(id, name):
            // Remember this bonded, location-capable camera so a later launch retrieves it directly, no scan needed —
            // including its "Cnct. while Power OFF" state (informational; fresh if we saw an advertisement this
            // connect, else whatever was last persisted — a standing-connect reconnect sees no advertisement).
            let cwpo = lastSeenConnectsWhilePoweredOff ?? bondedStore.load()?.connectsWhilePoweredOff
            bondedStore.save(RememberedCamera(id: id, name: name, connectsWhilePoweredOff: cwpo))
            eventContinuation.yield(.cameraIdentified(peripheralID: id, name: name))
            // Best-effort clock sync (beta): the link no-ops when CC13 is absent.
            pendingGPSClockSync = false
            writeClockSync(now: Date())
            apply(engine.reduce(&state, .connected))

        case .connectFailed:
            apply(engine.reduce(&state, .connectFailed))

        case .disconnected:
            apply(engine.reduce(&state, .disconnected))

        case .standby:
            // Link held to a connected-but-powered-off camera: reflect standby (no push). A later drop re-arms the
            // background standing connect so geotagging resumes on power-on.
            apply(engine.reduce(&state, .cameraStandby))

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

    /// Best-effort CC13 clock write (the link no-ops when CC13 is absent). With "Use GPS time" on, the clock source
    /// is the latest GNSS fix's timestamp — but only a fresh one (a stale timestamp would set the camera slow);
    /// otherwise the write waits for the next submitted fix. With it off, the device clock is written immediately.
    private func writeClockSync(now: Date) {
        guard syncClock else { return }
        let date: Date
        if useGPSTime {
            guard let fix = lastFix, now.timeIntervalSince(fix.timestamp) < Self.gpsClockFreshnessSeconds else {
                pendingGPSClockSync = true // flushed by the next `submitLocation` while connected
                return
            }
            date = fix.timestamp
        } else {
            date = now
        }
        link?.writeTime(SonyTimePacket(date: date, timeZone: .current).encoded())
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
