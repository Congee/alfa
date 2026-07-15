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
    /// Passed through to `CameraLink`; `nil` opts this central out of CoreBluetooth state restoration (see there).
    private let restoreIdentifier: String?
    private var state = GeotagState()
    private var link: CameraLink?
    private var pushCount = 0
    private var lastEmittedConnection: CameraConnectionState = .idle

    // Phase 2 remote control: a second pure engine beside the geotag policy, same actor (both must serialize
    // writes through the one link), wholly independent state. Its actions can express only command writes and
    // timeout arming — never a connection change (the anti-churn invariant is structural).
    private let remoteEngine = RemoteControlEngine()
    private var remoteState = RemoteControlState()
    private var lastEmittedRemoteState = RemoteControlState()
    /// In-flight capture-sequence timeouts, keyed by kind (the reducer's own phase guards ensure at most one of
    /// each is meaningful). Stale fires are additionally rejected by the reducer's generation tag, so correctness
    /// never depends on `cancel()` winning a race against the sleep.
    private var remoteTimeouts: [RemoteTimeout.Kind: Task<Void, Never>] = [:]
    /// RSSI poll cadence for the remote UI's signal indicator — slow enough to be battery-irrelevant.
    private static let rssiPollIntervalSeconds: TimeInterval = 2
    /// Whether the remote UI is on a lit screen. Mirrored (not just forwarded) because a poll started while
    /// disconnected self-terminates at the link — a camera that connects *after* the Remote tab is already
    /// visible needs the poll re-armed at the connect transition (see `apply`).
    private var remoteUIVisible = false

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
    // Mirrored from `GeotagSettings.updateOnFocus`: a focus acquisition (FF02) triggers an immediate fresh-position
    // push. The link subscribes to FF02 regardless (listen-only, no cost); this flag gates only the reaction.
    private var updateOnFocus = true
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
        bondedStore: BondedCameraStore = UserDefaultsBondedCameraStore(),
        restoreIdentifier: String? = "me.congee.alfa.central"
    ) {
        self.policy = policy
        self.bondedStore = bondedStore
        self.restoreIdentifier = restoreIdentifier
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
            restoreIdentifier: restoreIdentifier,
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
        // The connection transition above already reset the remote engine's beliefs; the Tasks just need killing.
        remoteTimeouts.values.forEach { $0.cancel() }
        remoteTimeouts = [:]
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

    /// Toggles "update location on focus": whether a camera focus acquisition (FF02 half-press status) triggers an
    /// immediate fresh-position push. See ``GeotagSettings/updateOnFocus``.
    public func setUpdateOnFocus(_ enabled: Bool) {
        updateOnFocus = enabled
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

    // MARK: - Remote control (Phase 2)

    /// Tap-mode shutter: runs the safe autonomous capture sequence (half → focus-ack/timeout → full → release).
    public func shutterTapped() {
        applyRemote(remoteEngine.reduce(&remoteState, .shutterAutoSequenceRequested(now: Date())))
    }

    /// Gesture-driven shutter stages (sustained half in tap mode; both stages in two-stage touch mode).
    public func shutterHalfDown() {
        applyRemote(remoteEngine.reduce(&remoteState, .shutterHalfDown(now: Date())))
    }

    public func shutterHalfUp() {
        applyRemote(remoteEngine.reduce(&remoteState, .shutterHalfUp(now: Date())))
    }

    public func shutterFullDown() {
        applyRemote(remoteEngine.reduce(&remoteState, .shutterFullDown(now: Date())))
    }

    public func shutterFullUp() {
        applyRemote(remoteEngine.reduce(&remoteState, .shutterFullUp(now: Date())))
    }

    public func shutterGestureCancelled() {
        applyRemote(remoteEngine.reduce(&remoteState, .shutterCancelled(now: Date())))
    }

    public func buttonDown(_ button: RemoteHoldButton) {
        applyRemote(remoteEngine.reduce(&remoteState, .buttonDown(button, now: Date())))
    }

    public func buttonUp(_ button: RemoteHoldButton) {
        applyRemote(remoteEngine.reduce(&remoteState, .buttonUp(button, now: Date())))
    }

    public func buttonLockToggled(_ button: RemoteHoldButton) {
        applyRemote(remoteEngine.reduce(&remoteState, .buttonLockToggled(button, now: Date())))
    }

    public func recordTapped() {
        applyRemote(remoteEngine.reduce(&remoteState, .recordTapped(now: Date())))
    }

    /// Starts/stops the RSSI poll for the remote UI's signal indicator — driven by the Remote tab's visibility,
    /// so an idle app never reads RSSI.
    public func setRemoteUIVisible(_ visible: Bool) {
        remoteUIVisible = visible
        if visible {
            link?.startRSSIPolling(interval: Self.rssiPollIntervalSeconds)
        } else {
            link?.stopRSSIPolling()
        }
    }

    #if DEBUG
    /// Zoom/MF opcode probe (docs/03 — the groups are disputed): fires raw bytes through the same gated FF01
    /// write path, deliberately bypassing the remote engine — a probe triple is not a modeled button and must
    /// never be interpreted as one. Debug builds only; results are read from the FF02 log.
    public func sendProbeCommand(_ bytes: [UInt8]) {
        guard state.connection == .connected else { return }
        link?.writeRemoteCommand(bytes)
    }
    #endif

    /// Applies remote-engine actions (command writes + timeout arming) and republishes the remote state on change.
    private func applyRemote(_ actions: [RemoteControlAction]) {
        for action in actions {
            switch action {
            case let .sendCommand(bytes):
                link?.writeRemoteCommand(bytes)
            case let .armTimeout(timeout, after):
                remoteTimeouts[timeout.kind]?.cancel()
                remoteTimeouts[timeout.kind] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(after))
                    guard !Task.isCancelled else { return }
                    await self?.remoteTimedOut(timeout)
                }
            case let .cancelTimeout(kind):
                remoteTimeouts[kind]?.cancel()
                remoteTimeouts[kind] = nil
            }
        }
        if remoteState != lastEmittedRemoteState {
            lastEmittedRemoteState = remoteState
            eventContinuation.yield(.remoteControl(remoteState))
        }
    }

    private func remoteTimedOut(_ timeout: RemoteTimeout) {
        applyRemote(remoteEngine.reduce(&remoteState, .timedOut(timeout)))
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
            // `state.lastPushed` is the position this ack confirms — the UI's "what the camera has" (map marker).
            eventContinuation.yield(.locationPushed(count: pushCount, fix: state.lastPushed))

        case let .cameraPowerState(power):
            // CC05 is the camera's power/standby signal: a confirmed power-off proactively tears down the link and
            // backs off.
            if power == .off {
                apply(engine.reduce(&state, .cameraPoweredOff))
            }

        case let .remoteStatus(status):
            // FF02 is the remote status feed: a focus acquisition (half-press) or a fired shutter pushes the freshest
            // position — "update location on focus". The shutter trigger is not redundant: a back-button-focus shot
            // has no shot-coupled AF activation, and such a real A7R V photo emitted only the shutter pair
            // (`02 A0 20/00`, docs/08 IT-13); it also freshens the fix for the next frames of a burst. The reducer
            // guards and throttles.
            if updateOnFocus, status == .focusAcquired || status == .pictureBeingTaken {
                apply(engine.reduce(&state, .captureActivity(now: Date())))
            }
            // The same decoded status independently drives the remote-control engine (capture sequencing,
            // recording/exposing indicators) — one notify, two pure reducers.
            applyRemote(remoteEngine.reduce(&remoteState, .remoteStatus(status, now: Date())))

        case .notify:
            // Raw feeds with no policy meaning yet (DD01 location-enabled flag, the CC10 probe) — logged at the link.
            break

        case .wroteRemoteCommand:
            break // informational — the engine's beliefs advance on FF02 statuses, not write acks

        case let .remoteCommandWriteFailed(message):
            applyRemote(remoteEngine.reduce(&remoteState, .commandWriteFailed(message)))

        case let .rssi(value):
            eventContinuation.yield(.rssi(value))

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
            // Mirror the transition into the remote engine: leaving `.connected` resets its transient beliefs
            // (held buttons, in-flight sequences) so a reconnect never inherits a stale press.
            applyRemote(remoteEngine.reduce(&remoteState, .connectionChanged(state.connection)))
            // Re-arm the visibility-driven RSSI poll for a connect that lands after the Remote tab is already on
            // screen (the visibility edge fired while disconnected, where the link's poll self-terminates).
            if state.connection == .connected, remoteUIVisible {
                link?.startRSSIPolling(interval: Self.rssiPollIntervalSeconds)
            }
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
