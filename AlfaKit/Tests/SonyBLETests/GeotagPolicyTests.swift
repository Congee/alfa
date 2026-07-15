import Foundation
import Testing
@testable import SonyBLE

/// Tests for the pure Balanced-policy reducer. These pin the **anti-churn invariants** that are the reason the project
/// exists: a failed connect, a CC05 standby bail, or a location update while backed off must never produce a new
/// connect or scan. (A *genuinely* dropped `.connected` link does re-arm a standing connect — foreground or background
/// — so the camera resumes on power-on; the guard is that a disconnect following a standby bail is not `.connected`.)
@Suite("Balanced policy reducer")
struct GeotagPolicyTests {
    let engine = GeotagPolicyEngine(config: .balanced)

    private func fix(_ latitude: Double, _ longitude: Double) -> LocationFix {
        LocationFix(latitude: latitude, longitude: longitude, timestamp: Date(timeIntervalSince1970: 0), horizontalAccuracyMeters: 5)
    }

    private func fix(_ latitude: Double, _ longitude: Double, at seconds: TimeInterval) -> LocationFix {
        LocationFix(latitude: latitude, longitude: longitude, timestamp: Date(timeIntervalSince1970: seconds), horizontalAccuracyMeters: 5)
    }

    /// Engine that also enforces a 30 s minimum interval between pushes (distance stays at the balanced 25 m). The
    /// keep-alive is disabled here so these tests isolate the interval gate (otherwise expiry would push first).
    private var intervalEngine: GeotagPolicyEngine {
        GeotagPolicyEngine(config: ConnectionPolicy(
            minimumDistanceMeters: 25,
            minimumIntervalSeconds: 30,
            keepAliveSeconds: 0,
            stayConnectedWhileCameraOn: true,
            backOffInStandby: true
        ))
    }

    private func connectedState(_ engine: GeotagPolicyEngine, latest: LocationFix) -> GeotagState {
        var state = GeotagState()
        state.bluetoothReady = true
        _ = engine.reduce(&state, .setEnabled(true))
        state.latest = latest
        _ = engine.reduce(&state, .connected) // pushes `latest`; lastPushed = latest
        return state
    }

    private func enabledAndConnected() -> GeotagState {
        var state = GeotagState()
        state.bluetoothReady = true
        _ = engine.reduce(&state, .setEnabled(true))
        _ = engine.reduce(&state, .connected)
        return state
    }

    @Test("Enabling while Bluetooth is ready begins discovery")
    func enablingWhileReadyBeginsDiscovery() {
        var state = GeotagState()
        state.bluetoothReady = true
        let actions = engine.reduce(&state, .setEnabled(true))
        #expect(actions == [.beginDiscovery])
        #expect(state.connection == .scanning)
    }

    @Test("Enabling before Bluetooth is ready waits, then begins on power-on")
    func enablingBeforeBluetoothWaits() {
        var state = GeotagState()
        #expect(engine.reduce(&state, .setEnabled(true)).isEmpty)
        #expect(state.connection == .idle)
        #expect(engine.reduce(&state, .bluetoothState(ready: true)) == [.beginDiscovery])
        #expect(state.connection == .scanning)
    }

    @Test("A location update while backed off does nothing")
    func locationWhileBackedOffDoesNothing() {
        var state = enabledAndConnected()
        _ = engine.reduce(&state, .cameraPoweredOff) // deliberate standby → backed off (a genuine drop would reconnect)
        let actions = engine.reduce(&state, .location(fix(1, 1)))
        #expect(actions.isEmpty)
        #expect(state.connection == .backedOff)
    }

    @Test("A failed connect does not retry")
    func connectFailedDoesNotRetry() {
        var state = GeotagState()
        state.bluetoothReady = true
        _ = engine.reduce(&state, .setEnabled(true))
        let actions = engine.reduce(&state, .connectFailed)
        #expect(actions.isEmpty)
        #expect(state.connection == .backedOff)
    }

    @Test("On connect, the latest location is pushed (this is the time sync)")
    func connectedPushesLatest() {
        var state = GeotagState()
        state.bluetoothReady = true
        _ = engine.reduce(&state, .setEnabled(true))
        #expect(engine.reduce(&state, .location(fix(10, 10))).isEmpty) // scanning: no push yet
        #expect(engine.reduce(&state, .connected) == [.pushLocation(fix(10, 10))])
        #expect(state.connection == .connected)
    }

    @Test("While connected, location pushes only beyond the distance threshold")
    func pushesOnlyBeyondDistanceThreshold() {
        var state = GeotagState()
        state.bluetoothReady = true
        _ = engine.reduce(&state, .setEnabled(true))
        state.latest = fix(0, 0)
        _ = engine.reduce(&state, .connected) // pushes fix(0,0); lastPushed = (0,0)

        let near = fix(0, 0.00001) // ~1.1 m — below 25 m
        #expect(engine.reduce(&state, .location(near)).isEmpty)

        let far = fix(0, 0.001) // ~111 m — beyond 25 m
        #expect(engine.reduce(&state, .location(far)) == [.pushLocation(far)])
    }

    @Test("An explicit sync request is a way out of back-off")
    func syncRequestLeavesBackOff() {
        var state = enabledAndConnected()
        _ = engine.reduce(&state, .cameraPoweredOff) // standby bail → backed off, no auto-reconnect
        #expect(state.connection == .backedOff)
        let actions = engine.reduce(&state, .syncRequested)
        #expect(actions == [.beginDiscovery])
        #expect(state.connection == .scanning)
    }

    @Test("Disabling disconnects and returns to idle")
    func disablingDisconnects() {
        var state = enabledAndConnected()
        let actions = engine.reduce(&state, .setEnabled(false))
        #expect(actions == [.cancelDiscoveryAndDisconnect])
        #expect(state.connection == .idle)
    }

    @Test("Camera power-off backs off and drops the link")
    func cameraPoweredOffBacksOff() {
        var state = enabledAndConnected()
        let actions = engine.reduce(&state, .cameraPoweredOff)
        #expect(actions.contains(.cancelDiscoveryAndDisconnect))
        #expect(actions.contains(.backOff))
        #expect(state.connection == .backedOff)
    }

    @Test("Bluetooth powering off marks the link unavailable without issuing work")
    func bluetoothOffIsUnavailable() {
        var state = enabledAndConnected()
        let actions = engine.reduce(&state, .bluetoothState(ready: false))
        #expect(actions.isEmpty)
        #expect(state.connection == .unavailable)
    }

    @Test("Interval throttle blocks a moved-far fix until enough time has elapsed")
    func intervalThrottleBlocksUntilElapsed() {
        let engine = intervalEngine
        var state = connectedState(engine, latest: fix(0, 0, at: 0))

        // ~111 m away but only 10 s later → interval gate fails → blocked.
        #expect(engine.reduce(&state, .location(fix(0, 0.001, at: 10))).isEmpty)

        // ~111 m away and 40 s after the last push → both gates clear → pushes.
        let far = fix(0, 0.001, at: 40)
        #expect(engine.reduce(&state, .location(far)) == [.pushLocation(far)])
    }

    @Test("Interval elapsing without movement still does not push (both gates required)")
    func intervalWithoutMovementDoesNotPush() {
        let engine = intervalEngine
        var state = connectedState(engine, latest: fix(0, 0, at: 0))

        // 100 s later but essentially stationary (~1 m) → distance gate fails → no push.
        #expect(engine.reduce(&state, .location(fix(0, 0.00001, at: 100))).isEmpty)
    }

    // MARK: - Keep-alive heartbeat

    @Test("A heartbeat while connected re-pushes the last position with a fresh timestamp")
    func heartbeatRepushesWhileConnected() {
        var state = connectedState(engine, latest: fix(1, 2, at: 0))
        // Nothing has moved since connect; the heartbeat re-sends the same position, restamped to `now`.
        let actions = engine.reduce(&state, .heartbeat(now: Date(timeIntervalSince1970: 10)))
        #expect(actions == [.pushLocation(fix(1, 2, at: 10))])
    }

    @Test("A heartbeat does not advance the movement gate (it is not a real push)")
    func heartbeatDoesNotAdvanceGate() {
        var state = connectedState(engine, latest: fix(0, 0, at: 0)) // real lastPushed = (0,0)
        _ = engine.reduce(&state, .heartbeat(now: Date(timeIntervalSince1970: 2)))

        // A near fix, still within the keep-alive window (no expiry), stays below the 25 m gate relative to the *real*
        // last push → no push.
        #expect(engine.reduce(&state, .location(fix(0, 0.00001, at: 3))).isEmpty)
        // A far fix still pushes → the distance reference was untouched by the heartbeat.
        let far = fix(0, 0.001, at: 4)
        #expect(engine.reduce(&state, .location(far)) == [.pushLocation(far)])
    }

    @Test("A heartbeat never issues a write while disconnected or before any push (never wakes standby)")
    func heartbeatDoesNothingWhenNotPushing() {
        // Connected but nothing pushed yet (no latest) → no lastPushed → nothing to keep alive.
        var state = enabledAndConnected()
        #expect(engine.reduce(&state, .heartbeat(now: Date(timeIntervalSince1970: 10))).isEmpty)

        // Backed off after a standby bail → a heartbeat must not produce a write (anti-churn).
        _ = engine.reduce(&state, .cameraPoweredOff)
        #expect(engine.reduce(&state, .heartbeat(now: Date(timeIntervalSince1970: 20))).isEmpty)
        #expect(state.connection == .backedOff)
    }

    @Test("A slow move under the distance gate still pushes the fresh fix once the keep-alive window elapses")
    func expiryPushesFreshWhileMovingSlowly() {
        var state = connectedState(engine, latest: fix(0, 0, at: 0)) // lastPushed = (0,0), lastWriteAt = 0
        // ~1 m move within the keep-alive window → still gated (distance + not yet stale).
        #expect(engine.reduce(&state, .location(fix(0, 0.00001, at: 20))).isEmpty)
        // ~2 m move but ≥45 s (keepAliveSeconds) since the last write → expiry forces the *fresh* fix through.
        let fresh = fix(0, 0.00002, at: 45)
        #expect(engine.reduce(&state, .location(fresh)) == [.pushLocation(fresh)])
    }

    @Test("Keep-alive overrides the interval throttle (a fix must never be allowed to expire)")
    func keepAliveOverridesInterval() {
        let engine = GeotagPolicyEngine(config: ConnectionPolicy(
            minimumDistanceMeters: 25,
            minimumIntervalSeconds: 60,
            keepAliveSeconds: 10,
            stayConnectedWhileCameraOn: true,
            backOffInStandby: true
        ))
        var state = connectedState(engine, latest: fix(0, 0, at: 0))
        // Moved far but only 10 s later: the 60 s interval blocks it as a *movement* push — yet the 10 s keep-alive
        // forces the write through, because letting the fix expire is never acceptable.
        let far = fix(0, 0.001, at: 10)
        #expect(engine.reduce(&state, .location(far)) == [.pushLocation(far)])
    }

    // MARK: - Reconnect (foreground and background)

    @Test("A genuinely dropped link reconnects — foreground OR background (power-on recovery)")
    func genuineDropReconnects() {
        var state = enabledAndConnected() // background by default: reconnect must still fire
        let actions = engine.reduce(&state, .disconnected)
        #expect(actions == [.beginDiscovery])
        #expect(state.connection == .scanning)
    }

    @Test("A dormant standby link holds without pushing (link to a powered-off camera)")
    func standbyHoldsWithoutPushing() {
        var state = GeotagState()
        state.bluetoothReady = true
        _ = engine.reduce(&state, .setEnabled(true)) // scanning
        // The standing connect linked to an off-but-connectable camera: hold dormant, push nothing.
        let actions = engine.reduce(&state, .cameraStandby)
        #expect(actions.isEmpty)
        #expect(state.connection == .standby)
        // A location update while dormant must never write to the off camera.
        #expect(engine.reduce(&state, .location(fix(1, 1))).isEmpty)
        #expect(engine.reduce(&state, .heartbeat(now: Date(timeIntervalSince1970: 60))).isEmpty)
    }

    @Test("A drop from standby re-arms the standing connect (power-on resume)")
    func standbyDropReconnects() {
        var state = GeotagState()
        state.bluetoothReady = true
        _ = engine.reduce(&state, .setEnabled(true))
        _ = engine.reduce(&state, .cameraStandby)
        #expect(state.connection == .standby)
        // The dormant link drops (camera cycled / iOS dropped it) — must re-establish, not back off.
        let actions = engine.reduce(&state, .disconnected)
        #expect(actions == [.beginDiscovery])
        #expect(state.connection == .scanning)
    }

    @Test("Standby is ignored when not pursuing a link (no phantom standby)")
    func standbyIgnoredWhenIdle() {
        var state = GeotagState() // disabled, idle
        let actions = engine.reduce(&state, .cameraStandby)
        #expect(actions.isEmpty)
        #expect(state.connection == .idle)
    }

    @Test("A powered-on camera leaves standby for connected (resume)")
    func standbyToConnectedOnPowerOn() {
        var state = GeotagState()
        state.bluetoothReady = true
        _ = engine.reduce(&state, .setEnabled(true))
        _ = engine.reduce(&state, .cameraStandby)
        #expect(state.connection == .standby)
        // The handshake finally acknowledges (camera powered on) → `.connected`, and the first fix pushes.
        state.latest = fix(2, 3)
        let actions = engine.reduce(&state, .connected)
        #expect(actions == [.pushLocation(fix(2, 3))])
        #expect(state.connection == .connected)
    }

    @Test("A CC05 standby bail does not reconnect (no wake-magnet loop)")
    func standbyBailDoesNotReconnect() {
        var state = enabledAndConnected()
        // Camera reports standby → back off + tear down. The teardown itself produces a disconnect...
        let off = engine.reduce(&state, .cameraPoweredOff)
        #expect(off.contains(.cancelDiscoveryAndDisconnect))
        #expect(state.connection == .backedOff)
        // ...and that follow-on disconnect must NOT reconnect (backed off, not connected) — else we'd churn.
        let after = engine.reduce(&state, .disconnected)
        #expect(after.isEmpty)
        #expect(state.connection == .backedOff)
    }

    @Test("Returning to the foreground retries from back-off")
    func foregroundReturnRetriesFromBackOff() {
        var state = enabledAndConnected()
        _ = engine.reduce(&state, .cameraPoweredOff) // → backedOff (a standby bail)
        #expect(state.connection == .backedOff)
        let actions = engine.reduce(&state, .setForeground(true))
        #expect(actions == [.beginDiscovery])
        #expect(state.connection == .scanning)
    }

    @Test("Backgrounding keeps a pending connect armed (background reconnect stays live)")
    func backgroundingKeepsPendingConnect() {
        var state = GeotagState()
        state.bluetoothReady = true
        _ = engine.reduce(&state, .setEnabled(true)) // → scanning (+ beginDiscovery)
        #expect(state.connection == .scanning)
        let actions = engine.reduce(&state, .setForeground(false))
        #expect(actions.isEmpty) // not cancelled
        #expect(state.connection == .scanning) // still pursuing the link in the background
    }

    @Test("Backgrounding keeps a live connection (background geotagging continues)")
    func backgroundingKeepsLiveConnection() {
        var state = enabledAndConnected()
        let actions = engine.reduce(&state, .setForeground(false))
        #expect(actions.isEmpty)
        #expect(state.connection == .connected)
    }
}
