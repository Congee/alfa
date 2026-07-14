/// The **pure** Balanced-policy state machine (decision D4). No CoreBluetooth, no I/O — a deterministic reducer over
/// `Sendable` values, unit-tested on the host in `SonyBLETests`.
///
/// This is where the battery fix lives as *policy*: the invariants that a disconnect, a failed connect, or a location
/// update while in standby must **never** produce a new connect/scan intent (that is the multi-suitor churn described
/// in `docs/05-battery-strategy.md`). `CameraLink` supplies the CoreBluetooth mechanics; this type decides *when*.
public struct GeotagState: Sendable, Equatable {
    /// User has geotagging switched on.
    public var isEnabled = false
    /// Bluetooth is powered on and usable.
    public var bluetoothReady = false
    /// Current connection state.
    public var connection: CameraConnectionState = .idle
    /// Most recent location sample received (whether or not it was pushed).
    public var latest: LocationFix?
    /// Last location successfully handed to the camera (for the distance threshold).
    public var lastPushed: LocationFix?

    public init() {}
}

/// Inputs that drive the state machine.
public enum GeotagInput: Sendable, Equatable {
    case setEnabled(Bool)
    case bluetoothState(ready: Bool)
    /// The link is fully established: services discovered and the fw-gated handshake done.
    case connected
    case connectFailed
    case disconnected
    /// The camera reported (or was inferred to have entered) power-off / standby.
    case cameraPoweredOff
    case location(LocationFix)
    /// An explicit, low-frequency user trigger (e.g. "Sync now") — the only sanctioned way out of back-off.
    case syncRequested
}

/// Side effects the engine should perform. The actor translates these into `CameraLink` commands.
public enum GeotagAction: Sendable, Equatable {
    /// Retrieve an already-connected peripheral if present, otherwise start a bounded foreground scan.
    case beginDiscovery
    /// Stop scanning and drop any link (used on disable / camera-off).
    case cancelDiscoveryAndDisconnect
    /// Push a location+time packet (this doubles as the on-connect time sync).
    case pushLocation(LocationFix)
    /// Ensure no standing connect intent remains while the camera is in standby.
    case backOff
}

/// Applies `GeotagInput`s to `GeotagState`, returning the actions to perform. Pure and total.
public struct GeotagPolicyEngine: Sendable {
    public let config: ConnectionPolicy

    public init(config: ConnectionPolicy = .balanced) {
        self.config = config
    }

    public func reduce(_ state: inout GeotagState, _ input: GeotagInput) -> [GeotagAction] {
        switch input {
        case let .setEnabled(enabled):
            guard enabled != state.isEnabled else { return [] }
            state.isEnabled = enabled
            if enabled {
                return begin(&state, manual: false)
            }
            let wasActive = state.connection.isActive
            state.connection = .idle
            state.lastPushed = nil
            return wasActive ? [.cancelDiscoveryAndDisconnect] : []

        case let .bluetoothState(ready):
            state.bluetoothReady = ready
            guard ready else {
                state.connection = .unavailable
                return []
            }
            return begin(&state, manual: false)

        case .connected:
            state.connection = .connected
            if let fix = state.latest {
                state.lastPushed = fix
                return [.pushLocation(fix)] // on-connect push also carries the time/tz sync
            }
            return []

        case .connectFailed:
            // Anti-churn: a failed attempt does not retry. We wait for an explicit trigger.
            state.connection = state.isEnabled ? .backedOff : .idle
            return []

        case .disconnected:
            // Anti-churn core: never auto-reconnect inside a disconnect. This is the single most important rule.
            state.connection = state.isEnabled ? .backedOff : .idle
            return []

        case .cameraPoweredOff:
            let wasEnabled = state.isEnabled
            state.connection = wasEnabled ? .backedOff : .idle
            return wasEnabled ? [.cancelDiscoveryAndDisconnect, .backOff] : [.cancelDiscoveryAndDisconnect]

        case let .location(fix):
            state.latest = fix
            // Only push while genuinely connected — never let a location update wake a standby camera.
            guard state.connection == .connected else { return [] }
            if let last = state.lastPushed {
                // Both gates must clear: moved far enough AND (if an interval is set) waited long enough. The first
                // fix after connect has no `lastPushed`, so it always pushes (that push doubles as the time sync).
                let movedEnough = fix.distance(to: last) >= config.minimumDistanceMeters
                let waitedEnough = config.minimumIntervalSeconds <= 0
                    || fix.timestamp.timeIntervalSince(last.timestamp) >= config.minimumIntervalSeconds
                guard movedEnough, waitedEnough else { return [] }
            }
            state.lastPushed = fix
            return [.pushLocation(fix)]

        case .syncRequested:
            return begin(&state, manual: true)
        }
    }

    /// Begins discovery iff enabled and Bluetooth is ready. Back-off is only left on an explicit (`manual`) trigger.
    private func begin(_ state: inout GeotagState, manual: Bool) -> [GeotagAction] {
        guard state.isEnabled, state.bluetoothReady else { return [] }
        switch state.connection {
        case .idle, .unavailable:
            state.connection = .scanning
            return [.beginDiscovery]
        case .backedOff:
            guard manual else { return [] }
            state.connection = .scanning
            return [.beginDiscovery]
        case .scanning, .connecting, .connected:
            return []
        }
    }
}
