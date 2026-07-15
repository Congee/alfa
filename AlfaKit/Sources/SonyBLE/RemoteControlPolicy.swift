import Foundation
import SonyProtocol

/// Pure remote-control state machine (Phase 2) — sibling of ``GeotagPolicyEngine``, same discipline: a total
/// function over `Sendable` value types, `now`/timeouts injected, zero I/O, host-tested exhaustively.
///
/// It owns the one protocol-fragile choreography in Phase 2 (docs/03): a bare full-press is ignored ~2/3 of the
/// time and wrong ordering can lock the camera's remote input, so **every** shutter path funnels through the same
/// half-before-full sequencing here. By construction it can never affect the connection lifecycle:
/// ``RemoteControlAction`` has no connect/scan/disconnect case — ``GeotagPolicyEngine`` remains the sole
/// connection owner (docs/05).

// MARK: - State

public struct RemoteControlState: Sendable, Equatable {
    /// Mirrored connection precondition: inputs are honored only while `.connected`. Leaving `.connected` resets
    /// every transient belief (held buttons, in-flight sequences) so a reconnect never inherits a stale press.
    public var connection: CameraConnectionState = .idle
    public var shutter: ShutterPhase = .idle
    public var afOn: HeldButtonPhase = .idle
    public var c1: HeldButtonPhase = .idle
    /// Wire-confirmed recording state (`FF02 02 D5`), not a local belief.
    public var isRecording = false
    /// Last `02 3F` focus indication from the camera (independent of any sequence we run).
    public var focus: FocusIndicator = .unknown
    /// False after `02 C3 00` — the camera's Bluetooth remote-control setting is off; any other FF02 traffic
    /// flips it back on (the feed is demonstrably live).
    public var remoteFeatureActive = true
    public var lastFailure: RemoteFailure?
    /// Wire-observed exposure span (`02 A0 20` → `02 A0 00`), regardless of who triggered the shot — the physical
    /// shutter button shows here too. Drives the "Exposing" indicator + elapsed display.
    public var exposureStartedAt: Date?
    /// Duration of the last completed exposure — the UI's long-exposure-NR *estimate* (the protocol has no NR
    /// signal; the second exposure of in-camera NR is about as long as the first).
    public var lastExposureSeconds: TimeInterval?
    /// Wire-observed recording start (`02 D5 20`) for the elapsed display.
    public var recordingStartedAt: Date?
    /// Bumped every time a timeout is armed; a firing timeout carrying a stale generation is ignored, so
    /// correctness never depends on `Task.cancel()` winning a race against an in-flight sleep.
    public var generation = 0

    public init() {}

    /// Coarse activity for the UI's state indicator (Disconnected/Connected/Focusing/Exposing/Recording).
    public var activity: RemoteActivity {
        guard connection == .connected else { return .disconnected }
        if isRecording { return .recording }
        if exposureStartedAt != nil { return .exposing }
        if shutter == .autoFocusing || shutter == .halfHeld || focus == .busy { return .focusing }
        return .connected
    }
}

public enum ShutterPhase: Sendable, Equatable {
    case idle
    /// Half-press held by the user's gesture (sustained-half in tap mode, or first finger in two-stage mode).
    case halfHeld
    /// Auto sequence: half sent, awaiting the focus-ack (or its timeout) before escalating to full.
    case autoFocusing
    /// Auto sequence: full sent, awaiting shutter-active (or its timeout) before releasing through.
    case autoFiring
    /// Two-stage mode: full held by the user's gesture (bulb-capable — the user's finger times the exposure).
    case fullHeld
}

public enum HeldButtonPhase: Sendable, Equatable { case idle, held, locked }

public enum FocusIndicator: Sendable, Equatable { case unknown, ready, acquired, busy }

public enum RemoteActivity: Sendable, Equatable { case disconnected, connected, focusing, exposing, recording }

/// The press-and-hold buttons. Record is deliberately not one of these: on the wire it is a toggle pair
/// (`01 0F`/`01 0E`), so it gets a dedicated tap input instead of faked hold semantics.
public enum RemoteHoldButton: Sendable, Equatable, CaseIterable { case afOn, c1 }

public enum RemoteFailure: Sendable, Equatable {
    case shutterTimedOut
    case remoteFeatureInactive
    case writeFailed(String)
}

/// Generation-tagged timeout identity (see ``RemoteControlState/generation``).
public struct RemoteTimeout: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable { case focusAck, shutterActive }
    public let kind: Kind
    public let generation: Int
    public init(kind: Kind, generation: Int) {
        self.kind = kind
        self.generation = generation
    }
}

// MARK: - Inputs / actions

public enum RemoteControlInput: Sendable, Equatable {
    /// Tap-mode shutter: run the full safe sequence autonomously (half → focus-ack/timeout → full → active → release).
    case shutterAutoSequenceRequested(now: Date)
    /// Gesture-driven shutter stages (sustained-half in tap mode; both stages in two-stage touch mode).
    case shutterHalfDown(now: Date)
    case shutterHalfUp(now: Date)
    case shutterFullDown(now: Date)
    case shutterFullUp(now: Date)
    /// Gesture cancelled (touch stolen by the system) — release whatever is down.
    case shutterCancelled(now: Date)
    /// Momentary press/release of a hold button; the gesture layer decides what a touch means.
    case buttonDown(RemoteHoldButton, now: Date)
    case buttonUp(RemoteHoldButton, now: Date)
    /// Lock toggle: latches the button pressed without a finger on it (and unlatches on the next toggle).
    /// While the button is `.held`, locking keeps the already-sent press and just latches it.
    case buttonLockToggled(RemoteHoldButton, now: Date)
    /// Record is a toggle on the wire — one tap sends the press/release pulse; `02 D5` confirms the outcome.
    case recordTapped(now: Date)
    /// Every FF02 status transition (decoded at the link).
    case remoteStatus(SonyRemoteStatus, now: Date)
    /// An armed timeout fired (stale generations are ignored).
    case timedOut(RemoteTimeout)
    /// An FF01 write was rejected or skipped — abort in-flight beliefs.
    case commandWriteFailed(String)
    case connectionChanged(CameraConnectionState)
}

public enum RemoteControlAction: Sendable, Equatable {
    case sendCommand([UInt8])
    case armTimeout(RemoteTimeout, after: TimeInterval)
    case cancelTimeout(RemoteTimeout.Kind)
}

// MARK: - Engine

public struct RemoteControlEngine: Sendable {
    /// How long an auto sequence waits for the focus-ack before escalating to full anyway. Escalating (not
    /// failing) is deliberate: an MF lens never sends `02 3F 20`, and the camera's own release-priority setting
    /// remains the authority on whether an unfocused shot fires.
    public static let focusAckTimeoutSeconds: TimeInterval = 3
    /// How long a sent full-press waits for shutter-active before the sequence gives up and releases through.
    public static let shutterActiveTimeoutSeconds: TimeInterval = 3

    public init() {}

    public func reduce(_ state: inout RemoteControlState, _ input: RemoteControlInput) -> [RemoteControlAction] {
        switch input {
        // MARK: Shutter — auto sequence

        case .shutterAutoSequenceRequested:
            guard userInputAllowed(state), state.shutter == .idle else { return [] }
            state.lastFailure = nil
            if state.focus == .acquired {
                // Focus is already locked (e.g. AF-ON held, on-camera back-button focus) — the camera may not
                // re-announce it for our half-press, so escalate immediately rather than risk a pointless wait.
                return [.sendCommand(SonyRemoteCommand.shutterHalf.press)] + escalateToFull(&state)
            }
            state.shutter = .autoFocusing
            state.generation += 1
            let timeout = RemoteTimeout(kind: .focusAck, generation: state.generation)
            return [
                .sendCommand(SonyRemoteCommand.shutterHalf.press),
                .armTimeout(timeout, after: Self.focusAckTimeoutSeconds),
            ]

        // MARK: Shutter — gesture-driven stages

        case .shutterHalfDown:
            guard userInputAllowed(state), state.shutter == .idle else { return [] }
            state.lastFailure = nil
            state.shutter = .halfHeld
            return [.sendCommand(SonyRemoteCommand.shutterHalf.press)]

        case .shutterHalfUp:
            switch state.shutter {
            case .halfHeld:
                state.shutter = .idle
                return [.sendCommand(SonyRemoteCommand.shutterHalf.release)]
            case .fullHeld:
                // Fingers lifted out of order (or together): release in full→half order, never half-under-full.
                state.shutter = .idle
                return [
                    .sendCommand(SonyRemoteCommand.shutterFull.release),
                    .sendCommand(SonyRemoteCommand.shutterHalf.release),
                ]
            default:
                return []
            }

        case .shutterFullDown:
            guard userInputAllowed(state) else { return [] }
            switch state.shutter {
            case .halfHeld:
                state.shutter = .fullHeld
                return [.sendCommand(SonyRemoteCommand.shutterFull.press)]
            case .idle:
                // Defensive: both fingers landed in the same gesture frame. Order the presses ourselves —
                // a bare full-press is the documented ~2/3-ignored case.
                state.lastFailure = nil
                state.shutter = .fullHeld
                return [
                    .sendCommand(SonyRemoteCommand.shutterHalf.press),
                    .sendCommand(SonyRemoteCommand.shutterFull.press),
                ]
            default:
                return []
            }

        case .shutterFullUp:
            guard state.shutter == .fullHeld else { return [] }
            state.shutter = .halfHeld // the first finger is still down; its own lift sends the half release
            return [.sendCommand(SonyRemoteCommand.shutterFull.release)]

        case .shutterCancelled:
            return releaseThrough(&state)

        // MARK: Hold buttons (AF-ON / C1)

        case let .buttonDown(button, _):
            guard userInputAllowed(state), state[button] == .idle else { return [] }
            state.lastFailure = nil
            state[button] = .held
            return [.sendCommand(Self.command(for: button).press)]

        case let .buttonUp(button, _):
            guard state[button] == .held else { return [] } // a locked button ignores the finger lifting
            state[button] = .idle
            return [.sendCommand(Self.command(for: button).release)]

        case let .buttonLockToggled(button, _):
            guard userInputAllowed(state) else { return [] }
            switch state[button] {
            case .idle:
                state.lastFailure = nil
                state[button] = .locked
                return [.sendCommand(Self.command(for: button).press)]
            case .held:
                state[button] = .locked // press already on the wire — just latch it
                return []
            case .locked:
                state[button] = .idle
                return [.sendCommand(Self.command(for: button).release)]
            }

        // MARK: Record (wire-level toggle)

        case .recordTapped:
            guard userInputAllowed(state) else { return [] }
            state.lastFailure = nil
            // Press/release pulse; the actual recording state lands via `02 D5` (never assumed locally).
            return [
                .sendCommand(SonyRemoteCommand.record.press),
                .sendCommand(SonyRemoteCommand.record.release),
            ]

        // MARK: Camera status (FF02)

        case let .remoteStatus(status, now):
            return reduceStatus(&state, status, now: now)

        // MARK: Timeouts / failures / lifecycle

        case let .timedOut(timeout):
            guard timeout.generation == state.generation else { return [] } // stale — superseded or cancelled
            switch (timeout.kind, state.shutter) {
            case (.focusAck, .autoFocusing):
                // No focus-ack (MF lens, or AF still hunting): escalate anyway — the camera's release-priority
                // setting decides whether the shot fires; failing here would break MF lenses entirely.
                return escalateToFull(&state)
            case (.shutterActive, .autoFiring):
                state.shutter = .idle
                state.lastFailure = .shutterTimedOut
                return [
                    .sendCommand(SonyRemoteCommand.shutterFull.release),
                    .sendCommand(SonyRemoteCommand.shutterHalf.release),
                ]
            default:
                return []
            }

        case let .commandWriteFailed(message):
            // The camera never saw whatever we believed was pressed — drop every transient belief without
            // sending more writes (they would fail the same way).
            state.lastFailure = .writeFailed(message)
            return abandonTransientState(&state)

        case let .connectionChanged(connection):
            state.connection = connection
            guard connection != .connected else { return [] }
            // Leaving `.connected`: the link owns no presses any more; reset beliefs, cancel timers, no writes.
            state.focus = .unknown
            state.isRecording = false
            state.recordingStartedAt = nil
            state.exposureStartedAt = nil
            return abandonTransientState(&state)
        }
    }

    // MARK: - Status handling

    private func reduceStatus(
        _ state: inout RemoteControlState,
        _ status: SonyRemoteStatus,
        now: Date
    ) -> [RemoteControlAction] {
        if status == .remoteFeatureInactive {
            // The camera's Bluetooth remote-control setting is off: nothing we press can land. Abort in-flight
            // beliefs without further writes and surface the one failure the user can actually fix on-camera.
            state.remoteFeatureActive = false
            state.lastFailure = .remoteFeatureInactive
            return abandonTransientState(&state)
        }
        state.remoteFeatureActive = true // any other FF02 traffic proves the feed is live

        switch status {
        case .focusReady:
            state.focus = .ready
            return []
        case .focusBusy:
            state.focus = .busy
            return []
        case .focusAcquired:
            state.focus = .acquired
            guard state.shutter == .autoFocusing else { return [] }
            return [.cancelTimeout(.focusAck)] + escalateToFull(&state)
        case .pictureBeingTaken:
            if state.exposureStartedAt == nil { state.exposureStartedAt = now }
            guard state.shutter == .autoFiring else { return [] }
            // The shot is in motion — release through; the camera finishes the exposure on its own.
            state.shutter = .idle
            return [
                .cancelTimeout(.shutterActive),
                .sendCommand(SonyRemoteCommand.shutterFull.release),
                .sendCommand(SonyRemoteCommand.shutterHalf.release),
            ]
        case .shutterReady:
            if let startedAt = state.exposureStartedAt {
                state.lastExposureSeconds = now.timeIntervalSince(startedAt)
                state.exposureStartedAt = nil
            }
            return []
        case .recordingStarted:
            state.isRecording = true
            if state.recordingStartedAt == nil { state.recordingStartedAt = now }
            return []
        case .recordingStopped:
            state.isRecording = false
            state.recordingStartedAt = nil
            return []
        case .remoteFeatureInactive, .unknown:
            return []
        }
    }

    // MARK: - Helpers

    /// Sends the full-press and arms its ack timeout — the shared escalation step of the auto sequence.
    private func escalateToFull(_ state: inout RemoteControlState) -> [RemoteControlAction] {
        state.shutter = .autoFiring
        state.generation += 1
        let timeout = RemoteTimeout(kind: .shutterActive, generation: state.generation)
        return [
            .sendCommand(SonyRemoteCommand.shutterFull.press),
            .armTimeout(timeout, after: Self.shutterActiveTimeoutSeconds),
        ]
    }

    /// Releases whatever the gesture layer had pressed (full before half), returning the shutter to idle.
    private func releaseThrough(_ state: inout RemoteControlState) -> [RemoteControlAction] {
        var commands: [RemoteControlAction] = []
        switch state.shutter {
        case .fullHeld, .autoFiring:
            commands = [
                .sendCommand(SonyRemoteCommand.shutterFull.release),
                .sendCommand(SonyRemoteCommand.shutterHalf.release),
            ]
        case .halfHeld, .autoFocusing:
            commands = [.sendCommand(SonyRemoteCommand.shutterHalf.release)]
        case .idle:
            break
        }
        state.shutter = .idle
        return cancelAllTimeouts(&state) + commands
    }

    /// Drops every transient belief (shutter phase, held/locked buttons) with **no** further writes — the paths
    /// that reach here (write failure, remote-inactive, disconnect) are exactly the ones where more writes are
    /// pointless or harmful. Timeout cancellation is still emitted so nothing stale fires later.
    private func abandonTransientState(_ state: inout RemoteControlState) -> [RemoteControlAction] {
        state.shutter = .idle
        state.afOn = .idle
        state.c1 = .idle
        return cancelAllTimeouts(&state)
    }

    private func cancelAllTimeouts(_ state: inout RemoteControlState) -> [RemoteControlAction] {
        state.generation += 1 // orphan any in-flight timeout even if its cancel races the sleep
        return [.cancelTimeout(.focusAck), .cancelTimeout(.shutterActive)]
    }

    private func userInputAllowed(_ state: RemoteControlState) -> Bool {
        state.connection == .connected && state.remoteFeatureActive
    }

    private static func command(for button: RemoteHoldButton) -> SonyRemoteCommand.Button {
        switch button {
        case .afOn: SonyRemoteCommand.afOn
        case .c1: SonyRemoteCommand.c1
        }
    }
}

private extension RemoteControlState {
    subscript(button: RemoteHoldButton) -> HeldButtonPhase {
        get {
            switch button {
            case .afOn: afOn
            case .c1: c1
            }
        }
        set {
            switch button {
            case .afOn: afOn = newValue
            case .c1: c1 = newValue
            }
        }
    }
}
