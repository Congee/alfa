import Foundation
import Testing
@testable import SonyBLE
@testable import SonyProtocol

/// Pins the Phase 2 remote-control state machine: the half-before-full capture ordering (docs/03 — a bare
/// full-press is ignored ~2/3 of the time and wrong ordering can lock the camera), timeout/abort convergence back
/// to idle, hold/lock button semantics, and the invariant that nothing here can ever touch the connection.
@Suite("Remote control policy")
struct RemoteControlPolicyTests {
    let engine = RemoteControlEngine()
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A connected state with the remote feature active — the precondition every user input requires.
    private func connectedState() -> RemoteControlState {
        var state = RemoteControlState()
        _ = engine.reduce(&state, .connectionChanged(.connected))
        return state
    }

    private func commands(_ actions: [RemoteControlAction]) -> [[UInt8]] {
        actions.compactMap {
            if case let .sendCommand(bytes) = $0 { return bytes }
            return nil
        }
    }

    // MARK: Auto sequence

    @Test("Auto sequence: half → focus-ack → full → shutter-active → release-through, in order")
    func autoSequenceHappyPath() {
        var state = connectedState()

        let start = engine.reduce(&state, .shutterAutoSequenceRequested(now: t0))
        #expect(commands(start) == [SonyRemoteCommand.shutterHalf.press])
        #expect(state.shutter == .autoFocusing)
        #expect(start.contains(.armTimeout(
            RemoteTimeout(kind: .focusAck, generation: state.generation),
            after: RemoteControlEngine.focusAckTimeoutSeconds
        )))

        let onFocus = engine.reduce(&state, .remoteStatus(.focusAcquired, now: t0 + 0.5))
        #expect(onFocus.first == .cancelTimeout(.focusAck))
        #expect(commands(onFocus) == [SonyRemoteCommand.shutterFull.press])
        #expect(state.shutter == .autoFiring)

        let onActive = engine.reduce(&state, .remoteStatus(.pictureBeingTaken, now: t0 + 0.8))
        #expect(commands(onActive) == [SonyRemoteCommand.shutterFull.release, SonyRemoteCommand.shutterHalf.release])
        #expect(state.shutter == .idle)
        #expect(state.exposureStartedAt == t0 + 0.8)

        _ = engine.reduce(&state, .remoteStatus(.shutterReady, now: t0 + 1.3))
        #expect(state.exposureStartedAt == nil)
        #expect(state.lastExposureSeconds == 0.5)
    }

    @Test("Auto sequence with focus already acquired escalates immediately (back-button-focus shooter)")
    func autoSequenceSkipsWaitWhenFocused() {
        var state = connectedState()
        _ = engine.reduce(&state, .remoteStatus(.focusAcquired, now: t0)) // AF-ON locked focus beforehand

        let start = engine.reduce(&state, .shutterAutoSequenceRequested(now: t0 + 1))
        #expect(commands(start) == [SonyRemoteCommand.shutterHalf.press, SonyRemoteCommand.shutterFull.press])
        #expect(state.shutter == .autoFiring)
    }

    @Test("Focus-ack timeout escalates to full anyway (MF lens) instead of failing")
    func focusTimeoutEscalates() {
        var state = connectedState()
        _ = engine.reduce(&state, .shutterAutoSequenceRequested(now: t0))
        let focusTimeout = RemoteTimeout(kind: .focusAck, generation: state.generation)

        let onTimeout = engine.reduce(&state, .timedOut(focusTimeout))
        #expect(commands(onTimeout) == [SonyRemoteCommand.shutterFull.press])
        #expect(state.shutter == .autoFiring)
        #expect(state.lastFailure == nil)
    }

    @Test("Shutter-active timeout releases through and reports the failure")
    func shutterActiveTimeoutReleasesThrough() {
        var state = connectedState()
        _ = engine.reduce(&state, .shutterAutoSequenceRequested(now: t0))
        _ = engine.reduce(&state, .remoteStatus(.focusAcquired, now: t0 + 0.5))
        let activeTimeout = RemoteTimeout(kind: .shutterActive, generation: state.generation)

        let onTimeout = engine.reduce(&state, .timedOut(activeTimeout))
        #expect(commands(onTimeout) == [SonyRemoteCommand.shutterFull.release, SonyRemoteCommand.shutterHalf.release])
        #expect(state.shutter == .idle)
        #expect(state.lastFailure == .shutterTimedOut)
    }

    @Test("A stale (superseded) timeout is a no-op")
    func staleTimeoutIgnored() {
        var state = connectedState()
        _ = engine.reduce(&state, .shutterAutoSequenceRequested(now: t0))
        let focusTimeout = RemoteTimeout(kind: .focusAck, generation: state.generation)
        _ = engine.reduce(&state, .remoteStatus(.focusAcquired, now: t0 + 0.1)) // bumps the generation

        let before = state
        #expect(engine.reduce(&state, .timedOut(focusTimeout)).isEmpty)
        #expect(state == before)
    }

    @Test("A second sequence request while one is in flight is ignored")
    func sequenceReentryIgnored() {
        var state = connectedState()
        _ = engine.reduce(&state, .shutterAutoSequenceRequested(now: t0))
        #expect(engine.reduce(&state, .shutterAutoSequenceRequested(now: t0 + 0.1)).isEmpty)
    }

    // MARK: Gesture-driven shutter (sustained half + two-stage touch)

    @Test("Sustained half: down holds the half-press, up releases it")
    func sustainedHalf() {
        var state = connectedState()
        let down = engine.reduce(&state, .shutterHalfDown(now: t0))
        #expect(commands(down) == [SonyRemoteCommand.shutterHalf.press])
        #expect(state.shutter == .halfHeld)
        #expect(state.activity == .focusing)

        let up = engine.reduce(&state, .shutterHalfUp(now: t0 + 2))
        #expect(commands(up) == [SonyRemoteCommand.shutterHalf.release])
        #expect(state.shutter == .idle)
    }

    @Test("Two-stage: second finger escalates to full, lifting it drops back to half")
    func twoStageEscalation() {
        var state = connectedState()
        _ = engine.reduce(&state, .shutterHalfDown(now: t0))

        let full = engine.reduce(&state, .shutterFullDown(now: t0 + 1))
        #expect(commands(full) == [SonyRemoteCommand.shutterFull.press])
        #expect(state.shutter == .fullHeld)

        let fullUp = engine.reduce(&state, .shutterFullUp(now: t0 + 3))
        #expect(commands(fullUp) == [SonyRemoteCommand.shutterFull.release])
        #expect(state.shutter == .halfHeld)

        let halfUp = engine.reduce(&state, .shutterHalfUp(now: t0 + 4))
        #expect(commands(halfUp) == [SonyRemoteCommand.shutterHalf.release])
        #expect(state.shutter == .idle)
    }

    @Test("Two-stage: both fingers landing at once still presses half before full")
    func bareFullGetsHalfFirst() {
        var state = connectedState()
        let both = engine.reduce(&state, .shutterFullDown(now: t0))
        #expect(commands(both) == [SonyRemoteCommand.shutterHalf.press, SonyRemoteCommand.shutterFull.press])
        #expect(state.shutter == .fullHeld)
    }

    @Test("Two-stage: all fingers lifting at once releases full before half")
    func outOfOrderLiftReleasesFullFirst() {
        var state = connectedState()
        _ = engine.reduce(&state, .shutterHalfDown(now: t0))
        _ = engine.reduce(&state, .shutterFullDown(now: t0 + 1))

        let lift = engine.reduce(&state, .shutterHalfUp(now: t0 + 2))
        #expect(commands(lift) == [SonyRemoteCommand.shutterFull.release, SonyRemoteCommand.shutterHalf.release])
        #expect(state.shutter == .idle)
    }

    @Test("A cancelled gesture releases whatever was down and converges to idle")
    func cancelReleasesThrough() {
        var state = connectedState()
        _ = engine.reduce(&state, .shutterHalfDown(now: t0))
        _ = engine.reduce(&state, .shutterFullDown(now: t0 + 1))

        let cancel = engine.reduce(&state, .shutterCancelled(now: t0 + 2))
        #expect(commands(cancel) == [SonyRemoteCommand.shutterFull.release, SonyRemoteCommand.shutterHalf.release])
        #expect(state.shutter == .idle)
    }

    // MARK: Hold buttons

    @Test("AF-ON press/release sends the state pair; a locked C1 is untouched by it")
    func holdButtonsAreIndependent() {
        var state = connectedState()
        _ = engine.reduce(&state, .buttonLockToggled(.c1, now: t0))
        #expect(state.c1 == .locked)

        let down = engine.reduce(&state, .buttonDown(.afOn, now: t0 + 1))
        #expect(commands(down) == [SonyRemoteCommand.afOn.press])
        #expect(state.afOn == .held)
        let up = engine.reduce(&state, .buttonUp(.afOn, now: t0 + 2))
        #expect(commands(up) == [SonyRemoteCommand.afOn.release])
        #expect(state.afOn == .idle)
        #expect(state.c1 == .locked)
    }

    @Test("Lock while held latches without re-sending; finger-up on a locked button sends nothing")
    func lockWhileHeld() {
        var state = connectedState()
        _ = engine.reduce(&state, .buttonDown(.afOn, now: t0))

        #expect(engine.reduce(&state, .buttonLockToggled(.afOn, now: t0 + 1)).isEmpty) // already pressed
        #expect(state.afOn == .locked)
        #expect(engine.reduce(&state, .buttonUp(.afOn, now: t0 + 2)).isEmpty) // lock survives the lift

        let unlock = engine.reduce(&state, .buttonLockToggled(.afOn, now: t0 + 3))
        #expect(commands(unlock) == [SonyRemoteCommand.afOn.release])
        #expect(state.afOn == .idle)
    }

    @Test("Record is a tap: one press/release pulse, state confirmed only by the wire")
    func recordToggle() {
        var state = connectedState()
        let tap = engine.reduce(&state, .recordTapped(now: t0))
        #expect(commands(tap) == [SonyRemoteCommand.record.press, SonyRemoteCommand.record.release])
        #expect(!state.isRecording) // not believed until 02 D5 confirms

        _ = engine.reduce(&state, .remoteStatus(.recordingStarted, now: t0 + 1))
        #expect(state.isRecording)
        #expect(state.recordingStartedAt == t0 + 1)
        #expect(state.activity == .recording)

        _ = engine.reduce(&state, .remoteStatus(.recordingStopped, now: t0 + 30))
        #expect(!state.isRecording)
        #expect(state.recordingStartedAt == nil)
    }

    // MARK: Aborts and preconditions

    @Test("remoteFeatureInactive aborts in-flight state with no further writes")
    func remoteInactiveAborts() {
        var state = connectedState()
        _ = engine.reduce(&state, .shutterAutoSequenceRequested(now: t0))
        _ = engine.reduce(&state, .buttonDown(.afOn, now: t0))

        let abort = engine.reduce(&state, .remoteStatus(.remoteFeatureInactive, now: t0 + 1))
        #expect(commands(abort).isEmpty)
        #expect(state.shutter == .idle)
        #expect(state.afOn == .idle)
        #expect(state.lastFailure == .remoteFeatureInactive)
        #expect(!state.remoteFeatureActive)

        // While inactive, user inputs are refused outright.
        #expect(engine.reduce(&state, .shutterHalfDown(now: t0 + 2)).isEmpty)

        // Any other FF02 traffic proves the feature came back on.
        _ = engine.reduce(&state, .remoteStatus(.focusReady, now: t0 + 3))
        #expect(state.remoteFeatureActive)
    }

    @Test("A rejected write takes back the presses already on the wire")
    func writeFailureReleasesThrough() {
        var state = connectedState()
        _ = engine.reduce(&state, .shutterHalfDown(now: t0))
        _ = engine.reduce(&state, .buttonLockToggled(.c1, now: t0))

        // Only the one write was rejected — the camera is still listening and still holding what we pressed.
        let abort = engine.reduce(&state, .commandWriteFailed("Unknown ATT error"))
        #expect(commands(abort) == [SonyRemoteCommand.shutterHalf.release, SonyRemoteCommand.c1.release])
        #expect(state.shutter == .idle)
        #expect(state.c1 == .idle)
        #expect(state.lastFailure == .writeFailed("Unknown ATT error"))

        // State is reset before the releases go out, so a release that fails in turn emits nothing — no cascade.
        #expect(commands(engine.reduce(&state, .commandWriteFailed("Unknown ATT error"))).isEmpty)
    }

    @Test("A locked button is released, not silently abandoned, when an unrelated write fails")
    func writeFailureNeverStrandsALockedButton() {
        var state = connectedState()
        #expect(commands(engine.reduce(&state, .buttonLockToggled(.afOn, now: t0)))
            == [SonyRemoteCommand.afOn.press])

        let abort = engine.reduce(&state, .commandWriteFailed("Unknown ATT error"))
        #expect(commands(abort) == [SonyRemoteCommand.afOn.release]) // or the camera holds AF-ON down forever
        #expect(state.afOn == .idle)

        // And the next lock tap is a fresh press — never a second press stacked on an unreleased one.
        #expect(commands(engine.reduce(&state, .buttonLockToggled(.afOn, now: t0 + 1)))
            == [SonyRemoteCommand.afOn.press])
        #expect(state.afOn == .locked)
    }

    @Test("A dead link is abandoned without writes — releases only go out while connected")
    func abandonsWithoutWritesWhenDisconnected() {
        var state = connectedState()
        _ = engine.reduce(&state, .buttonLockToggled(.afOn, now: t0))
        _ = engine.reduce(&state, .connectionChanged(.backedOff)) // clears beliefs, no writes

        state.afOn = .locked // a belief that outlived the link cannot be written away
        #expect(commands(engine.reduce(&state, .commandWriteFailed("link not ready"))).isEmpty)
        #expect(state.afOn == .idle)
    }

    @Test("remoteFeatureActive is a belief about one link, not a latch that outlives reconnects")
    func remoteFeatureActiveResetsOnReconnect() {
        var state = connectedState()
        _ = engine.reduce(&state, .remoteStatus(.remoteFeatureInactive, now: t0))
        #expect(!state.remoteFeatureActive)

        // The user enables the camera's Bluetooth remote setting; the link drops and comes back.
        _ = engine.reduce(&state, .connectionChanged(.backedOff))
        _ = engine.reduce(&state, .connectionChanged(.connected))
        #expect(state.remoteFeatureActive)
        #expect(state.lastFailure == nil) // the old link's failure is not this link's news

        // Without the reset the remote stays inert forever: Alfa sends nothing, so the camera emits no FF02
        // traffic, so nothing ever clears the flag.
        #expect(commands(engine.reduce(&state, .shutterAutoSequenceRequested(now: t0 + 1)))
            == [SonyRemoteCommand.shutterHalf.press])
    }

    @Test("Disconnecting resets every belief; inputs while disconnected are refused")
    func disconnectResets() {
        var state = connectedState()
        _ = engine.reduce(&state, .buttonLockToggled(.afOn, now: t0))
        _ = engine.reduce(&state, .remoteStatus(.recordingStarted, now: t0))
        _ = engine.reduce(&state, .remoteStatus(.pictureBeingTaken, now: t0))

        let drop = engine.reduce(&state, .connectionChanged(.backedOff))
        #expect(commands(drop).isEmpty) // no writes into a dead link
        #expect(state.afOn == .idle)
        #expect(!state.isRecording)
        #expect(state.exposureStartedAt == nil)
        #expect(state.activity == .disconnected)

        #expect(engine.reduce(&state, .shutterAutoSequenceRequested(now: t0 + 1)).isEmpty)
        #expect(engine.reduce(&state, .buttonDown(.afOn, now: t0 + 1)).isEmpty)
        #expect(engine.reduce(&state, .recordTapped(now: t0 + 1)).isEmpty)
    }

    @Test("No input can ever produce a connection action — the action type cannot express one")
    func actionsAreConnectionFree() {
        // The invariant is structural: RemoteControlAction has only sendCommand/armTimeout/cancelTimeout.
        // This test documents it by walking a full session's actions and asserting their shape.
        var state = connectedState()
        var all: [RemoteControlAction] = []
        all += engine.reduce(&state, .shutterAutoSequenceRequested(now: t0))
        all += engine.reduce(&state, .remoteStatus(.focusAcquired, now: t0 + 1))
        all += engine.reduce(&state, .remoteStatus(.pictureBeingTaken, now: t0 + 2))
        all += engine.reduce(&state, .connectionChanged(.backedOff))
        for action in all {
            switch action {
            case .sendCommand, .armTimeout, .cancelTimeout:
                continue // the only expressible shapes
            }
        }
    }

    @Test("An exposure started by the physical shutter button still drives the Exposing indicator")
    func physicalShutterObserved() {
        var state = connectedState()
        _ = engine.reduce(&state, .remoteStatus(.pictureBeingTaken, now: t0))
        #expect(state.activity == .exposing)
        #expect(state.shutter == .idle) // we pressed nothing

        _ = engine.reduce(&state, .remoteStatus(.shutterReady, now: t0 + 4))
        #expect(state.activity == .connected)
        #expect(state.lastExposureSeconds == 4)
    }
}
