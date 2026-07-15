import Foundation

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
    /// Last **distinct position** handed to the camera — the reference for the distance and interval gates. A keep-alive
    /// re-push of the same position does not change this.
    public var lastPushed: LocationFix?
    /// Wall-clock of the **last write of any kind** (a real position push *or* a keep-alive re-push) — the reference for
    /// the expiry/keep-alive check. Distinct from `lastPushed.timestamp` so keep-alives don't disturb the interval gate.
    public var lastWriteAt: Date?
    /// Wall-clock of the last capture-triggered push (focus acquired or shutter fired) — the reference for the
    /// capture-push throttle (continuous AF can re-acquire focus several times a second; bursts fire the shutter).
    public var lastCapturePushAt: Date?

    public init() {}
}

/// Inputs that drive the state machine.
public enum GeotagInput: Sendable, Equatable {
    case setEnabled(Bool)
    /// The app moved to/from the foreground. Returning to it retries from back-off (user present); leaving it is a
    /// deliberate no-op — a live link **and** any standing reconnect intent are kept so geotagging resumes in the
    /// background too. The anti-drain guard is the link layer's ack-gated standby hold, not backgrounding.
    case setForeground(Bool)
    case bluetoothState(ready: Bool)
    /// The link is fully established: services discovered and the fw-gated handshake done.
    case connected
    case connectFailed
    case disconnected
    /// The camera reported (or was inferred to have entered) power-off / standby.
    case cameraPoweredOff
    /// A link is held to a camera that is connected at the BLE layer but powered off (its handshake writes are
    /// rejected). Unlike `.cameraPoweredOff` (which tears the link down and backs off), this **keeps** the dormant link
    /// for background auto-resume: nothing is pushed, but a later drop re-arms the standing connect.
    case cameraStandby
    case location(LocationFix)
    /// Keep-alive tick: re-send the last pushed position with a fresh timestamp so the camera never ages out its
    /// location fix (the "Location information cannot be obtained" overlay). The camera announces this expiry over no
    /// BLE characteristic (`docs/03`, `docs/08`), so it can only be *prevented*, not reacted to. Carries `now` to keep
    /// the reducer pure and deterministic.
    case heartbeat(now: Date)
    /// The camera is actively shooting — focus acquired (FF02 `02 3F 20`) **or** shutter fired (`02 A0 20`): push the
    /// freshest position immediately so the shot (or the next frame of a burst) carries the most accurate location —
    /// Geotag Alpha's "update location on focus". The shutter code matters in practice: a back-button-focus shooter
    /// can take a photo without any shot-coupled AF activation, and such a real A7R V shot was observed emitting only
    /// the shutter pair (docs/08 IT-13). Bypasses the distance/interval gates (throttled by
    /// ``GeotagPolicyEngine/capturePushMinInterval`` instead). Carries `now` to stay pure.
    case captureActivity(now: Date)
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
                state.lastWriteAt = fix.timestamp
                return [.pushLocation(fix)] // on-connect push also carries the time/tz sync
            }
            return []

        case .connectFailed:
            // Anti-churn: a failed attempt does not retry. We wait for an explicit trigger.
            state.connection = state.isEnabled ? .backedOff : .idle
            return []

        case .disconnected:
            guard state.isEnabled else { state.connection = .idle; return [] }
            // A genuinely established link dropped: begin discovery to re-establish it. *How* the reconnect behaves is
            // decided in `CameraLink` from the app's foreground state and the user's "Reconnect in background" setting:
            //   • foreground — scan, inspect the advertisement's power flags, and connect only to a powered-on camera
            //     (or, seeing no advertisement at all, direct-connect the known camera);
            //   • background + setting on — hold a standing connect() so iOS resumes on the camera's next power-on
            //     (relaunching us via state restoration). Free by construction for a camera that goes silent when off
            //     ("Cnct. while Power OFF" = Off); a still-connectable off camera is answered but held dormant in
            //     `.standby` without a single write (Alfa adds no churn — absolute drain pending `docs/08` IT-10);
            //   • background + setting off — back off (no blind connect); resume on foreground / "Sync now".
            // Either way we do NOT reconnect when the disconnect is the *result of our own standby back-off*: after a
            // `CC05` standby bail the connection is `.backedOff` (not `.connected`), so the follow-on teardown
            // disconnect stays down — that is the wake-magnet loop against a Cnct-while-Power-OFF camera.
            // A drop from a live link **or** a held dormant standby link (background auto-resume) re-establishes it;
            // a drop while merely scanning/backed-off does not (that would churn a standby camera).
            if state.bluetoothReady, state.connection == .connected || state.connection == .standby {
                state.connection = .scanning
                return [.beginDiscovery]
            }
            state.connection = .backedOff
            return []

        case let .setForeground(active):
            // Returning to the foreground retries from back-off (e.g. after a standby bail, or if the camera powered on
            // while we were away and iOS did not relaunch us). Leaving the foreground is intentionally a no-op: a live
            // link and any standing reconnect are **kept** so geotagging resumes in the background too. What prevents a
            // connectable-while-off camera from being churned is the link layer's ack-gated standby hold (writes are
            // never issued until the handshake acknowledges), not backgrounding.
            guard state.isEnabled, active else { return [] }
            return begin(&state, manual: true)

        case .cameraPoweredOff:
            let wasEnabled = state.isEnabled
            state.connection = wasEnabled ? .backedOff : .idle
            return wasEnabled ? [.cancelDiscoveryAndDisconnect, .backOff] : [.cancelDiscoveryAndDisconnect]

        case .cameraStandby:
            // Hold the dormant link (the link layer connected but the camera is powered off): reflect standby so the UI
            // is honest and a later drop re-arms the standing connect (see `.disconnected`). Push nothing — a write to
            // an off camera is rejected and only churns it. No effect unless we were pursuing/holding a link.
            guard state.isEnabled, state.connection.isActive else { return [] }
            state.connection = .standby
            return []

        case let .location(fix):
            state.latest = fix
            // Only push while genuinely connected — never let a location update wake a standby camera.
            guard state.connection == .connected else { return [] }
            if let last = state.lastPushed {
                // The first fix after connect has no `lastPushed`, so it always pushes (that push doubles as the time
                // sync). Otherwise push the *fresh* fix when **either** condition holds:
                //   • movement — moved far enough AND (if set) the interval has elapsed; or
                //   • expiry — the fix would otherwise go stale (keep-alive), pushing the current position rather than
                //     letting the heartbeat re-send a stale cached one. Expiry can override the interval throttle: a
                //     keep-alive must win, or the camera drops the fix.
                let movedEnough = fix.distance(to: last) >= config.minimumDistanceMeters
                let waitedEnough = config.minimumIntervalSeconds <= 0
                    || fix.timestamp.timeIntervalSince(last.timestamp) >= config.minimumIntervalSeconds
                guard (movedEnough && waitedEnough) || isExpiryDue(at: fix.timestamp, state) else { return [] }
            }
            state.lastPushed = fix
            state.lastWriteAt = fix.timestamp
            return [.pushLocation(fix)]

        case let .heartbeat(now):
            // Stationary keep-alive: when no fresh samples are arriving, re-send the *last position* with a current
            // timestamp to defeat the camera-side staleness timeout. It does **not** advance position or the
            // movement/interval gates. Guarded so it can never write while disconnected or backed off (that would risk
            // waking a standby camera): fires only while connected, only once a position has been pushed, and only when
            // the keep-alive is enabled. Timing is owned by the coordinator's timer (reset on every write), so no
            // elapsed-time check here — that would risk a scheduling-jitter miss stalling the keep-alive loop.
            guard config.keepAliveSeconds > 0,
                  state.connection == .connected,
                  let last = state.lastPushed else { return [] }
            let refreshed = LocationFix(
                latitude: last.latitude,
                longitude: last.longitude,
                timestamp: now,
                horizontalAccuracyMeters: last.horizontalAccuracyMeters
            )
            state.lastWriteAt = now
            return [.pushLocation(refreshed)]

        case let .captureActivity(now):
            // Capture-triggered push: the shot being taken should carry the freshest position, so the movement
            // and interval gates are bypassed. Guarded like every write — only while genuinely connected, only with
            // a sample in hand — and throttled so continuous-AF re-acquisitions and bursts can't spam the link. The
            // position is restamped to `now` (like a keep-alive) so the camera never sees a time-regressive packet
            // after a heartbeat, and it becomes the pushed reference the movement gate measures from.
            guard state.connection == .connected, let fix = state.latest else { return [] }
            if let lastCapturePushAt = state.lastCapturePushAt,
               now.timeIntervalSince(lastCapturePushAt) < Self.capturePushMinInterval {
                return []
            }
            let atCapture = LocationFix(
                latitude: fix.latitude,
                longitude: fix.longitude,
                timestamp: now,
                horizontalAccuracyMeters: fix.horizontalAccuracyMeters
            )
            state.lastCapturePushAt = now
            state.lastPushed = atCapture
            state.lastWriteAt = now
            return [.pushLocation(atCapture)]

        case .syncRequested:
            return begin(&state, manual: true)
        }
    }

    /// Minimum spacing between capture-triggered pushes. Focus events arrive per AF acquisition — continuous AF can
    /// fire several per second — and shutter events per frame in a burst; each push is a radio write, so they are
    /// rate-limited independently of the user-facing interval setting (which they deliberately bypass).
    public static let capturePushMinInterval: TimeInterval = 2

    /// Whether the camera's fix would go stale by `now` — i.e. the keep-alive window has elapsed since the last write.
    /// `false` when the keep-alive is disabled or nothing has been written yet.
    private func isExpiryDue(at now: Date, _ state: GeotagState) -> Bool {
        guard config.keepAliveSeconds > 0, let lastWriteAt = state.lastWriteAt else { return false }
        return now.timeIntervalSince(lastWriteAt) >= config.keepAliveSeconds
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
        case .scanning, .connecting, .connected, .standby:
            return []
        }
    }
}
