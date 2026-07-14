import Foundation
import Testing
@testable import SonyBLE

/// Tests for the pure Balanced-policy reducer. These pin the **anti-churn invariants** that are the reason the project
/// exists: a disconnect / failed connect / standby location update must never produce a new connect or scan.
@Suite("Balanced policy reducer")
struct GeotagPolicyTests {
    let engine = GeotagPolicyEngine(config: .balanced)

    private func fix(_ latitude: Double, _ longitude: Double) -> LocationFix {
        LocationFix(latitude: latitude, longitude: longitude, timestamp: Date(timeIntervalSince1970: 0), horizontalAccuracyMeters: 5)
    }

    private func fix(_ latitude: Double, _ longitude: Double, at seconds: TimeInterval) -> LocationFix {
        LocationFix(latitude: latitude, longitude: longitude, timestamp: Date(timeIntervalSince1970: seconds), horizontalAccuracyMeters: 5)
    }

    /// Engine that also enforces a 30 s minimum interval between pushes (distance stays at the balanced 25 m).
    private var intervalEngine: GeotagPolicyEngine {
        GeotagPolicyEngine(config: ConnectionPolicy(
            minimumDistanceMeters: 25,
            minimumIntervalSeconds: 30,
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

    @Test("A disconnect never triggers a reconnect (core anti-churn guard)")
    func disconnectNeverReconnects() {
        var state = enabledAndConnected()
        let actions = engine.reduce(&state, .disconnected)
        #expect(actions.isEmpty)
        #expect(state.connection == .backedOff)
    }

    @Test("A location update while backed off does nothing")
    func locationWhileBackedOffDoesNothing() {
        var state = enabledAndConnected()
        _ = engine.reduce(&state, .disconnected)
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

    @Test("An explicit sync request is the only way out of back-off")
    func syncRequestLeavesBackOff() {
        var state = enabledAndConnected()
        _ = engine.reduce(&state, .disconnected)
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
}
