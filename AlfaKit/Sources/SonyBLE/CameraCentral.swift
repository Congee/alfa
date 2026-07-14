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

    private let engine: GeotagPolicyEngine
    private var state = GeotagState()
    private var link: CameraLink?
    private var pushCount = 0
    private var lastEmittedConnection: CameraConnectionState = .idle

    private let eventContinuation: AsyncStream<CameraEvent>.Continuation
    private let linkEvents: AsyncStream<LinkEvent>
    private let linkEventContinuation: AsyncStream<LinkEvent>.Continuation
    private var consumeTask: Task<Void, Never>?

    public init(policy: ConnectionPolicy = .balanced) {
        self.policy = policy
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
            knownIdentifier: nil, // TODO(Phase 1): persist the bonded peripheral's UUID across launches
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

    // MARK: - Link event handling

    private func handle(_ event: LinkEvent) {
        switch event {
        case let .bluetoothState(poweredOn):
            apply(engine.reduce(&state, .bluetoothState(ready: poweredOn)))

        case let .discovered(id, name, rssi, manufacturerData):
            let model = manufacturerData.flatMap { SonyAdvertisement(manufacturerData: $0)?.modelCode } ?? name
            eventContinuation.yield(.discovered(peripheralID: id, modelCode: model, rssi: rssi))

        case .ready:
            apply(engine.reduce(&state, .connected))

        case .connectFailed:
            apply(engine.reduce(&state, .connectFailed))

        case .disconnected:
            apply(engine.reduce(&state, .disconnected))

        case .wroteLocation:
            pushCount += 1
            eventContinuation.yield(.locationPushed(count: pushCount))

        case .notify:
            break // Phase 1: DD01 location-enabled flag observed but not yet acted upon.

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
                let packet = SonyLocationPacket(
                    latitude: fix.latitude,
                    longitude: fix.longitude,
                    date: fix.timestamp,
                    timeZone: .current
                )
                link?.writeLocation(packet.encoded())
            }
        }
    }
}
