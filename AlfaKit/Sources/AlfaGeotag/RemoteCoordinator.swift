import Foundation
import SonyBLE
import SonyProtocol

/// The remote-control façade (Phase 2): mirrors ``SonyBLE/RemoteControlState`` into UI primitives and translates
/// gestures into `CameraCentral` calls — the same discipline as ``GeotagCoordinator``: the App layer never names a
/// `SonyBLE` type. It has **zero connection-lifecycle authority**: remote control rides whatever link the geotag
/// engine maintains, and everything here is inert while disconnected.
///
/// Constructed only by ``CameraSession`` (with the shared `CameraCentral` injected); events arrive via
/// ``GeotagCoordinator``'s single consumption loop, forwarded through its `remoteEventSink`.
@MainActor
@Observable
public final class RemoteCoordinator {
    /// App-facing shutter interaction mode (persisted). `tapAuto`: tap runs the safe autonomous capture sequence,
    /// press-and-hold sustains a half-press. `twoStage`: one finger holds half, a second finger fires full
    /// (bulb-capable — the finger times the exposure).
    public enum ShutterMode: String, CaseIterable, Sendable {
        case tapAuto
        case twoStage
    }

    /// The two press-and-hold buttons (Record is a tap — the wire models it as a toggle).
    public enum HoldButton: String, CaseIterable, Sendable {
        case afOn
        case c1
    }

    public enum HoldPhase: String, Sendable { case idle, held, locked }

    /// Coarse camera activity for the state banner.
    public enum Activity: String, Sendable { case disconnected, connected, focusing, exposing, recording }

    // MARK: - Observable state (all primitives / Foundation types)

    public private(set) var activity: Activity = .disconnected
    /// False after the camera reported `remote feature inactive` — its Bluetooth remote-control setting is off.
    public private(set) var remoteFeatureActive = true
    public private(set) var afOnPhase: HoldPhase = .idle
    public private(set) var c1Phase: HoldPhase = .idle
    /// True while any shutter stage is engaged (pressed visual state).
    public private(set) var isShutterEngaged = false
    public private(set) var isRecording = false
    /// Wire-confirmed recording start — drives the elapsed timer (`Text(_, style: .timer)`).
    public private(set) var recordingStartedAt: Date?
    /// Wire-observed exposure start (any trigger, including the physical shutter button).
    public private(set) var exposureStartedAt: Date?
    /// When the last exposure completed — anchors the transient long-exposure-NR countdown.
    public private(set) var exposureEndedAt: Date?
    /// Duration of the last completed exposure. For long exposures this is also the in-camera noise-reduction
    /// *estimate* (the protocol has no NR signal; the second exposure is about as long as the first).
    public private(set) var lastExposureSeconds: Double?
    /// Signal strength, 0–4 bars (nil until the first RSSI read while the Remote tab is visible).
    public private(set) var signalBars: Int?
    public private(set) var failureDescription: String?

    public private(set) var shutterMode: ShutterMode

    // MARK: - Wiring

    private let central: CameraCentral
    private let defaults: UserDefaults
    private static let shutterModeKey = "me.congee.alfa.remote.shutterMode"

    /// Gestures are queued here rather than each getting its own `Task`. Separately-created unstructured tasks reach
    /// an actor in an unspecified order — measured at ~2.7 % inversions for two submitted back to back (2026-08-16) —
    /// and the engine downstream exists precisely to enforce ordering. A reordered `buttonUp`/`buttonDown` pair leaves
    /// a button `.held` with a press on the wire and the finger already lifted.
    private let intents: AsyncStream<Intent>.Continuation

    init(central: CameraCentral, defaults: UserDefaults = .standard) {
        self.central = central
        self.defaults = defaults
        shutterMode = defaults.string(forKey: Self.shutterModeKey).flatMap(ShutterMode.init(rawValue:)) ?? .tapAuto

        // Unbounded: dropping a gesture is the failure this queue exists to prevent.
        let (stream, continuation) = AsyncStream.makeStream(of: Intent.self, bufferingPolicy: .unbounded)
        intents = continuation
        // Awaiting each call before taking the next is what serializes them. Captures `central`, not `self`, so the
        // pump never keeps this coordinator alive; `deinit` ends the stream and with it the loop.
        Task { [central] in
            for await intent in stream {
                await Self.deliver(intent, to: central)
            }
        }
    }

    deinit {
        intents.finish() // ends the pump's loop, and with it the task
    }

    // MARK: - Intents

    /// One gesture, in the order the finger made it.
    private enum Intent: Sendable {
        case shutterTapped
        case shutterHalfDown
        case shutterHalfUp
        case shutterFullDown
        case shutterFullUp
        case shutterCancelled
        case buttonDown(RemoteHoldButton)
        case buttonUp(RemoteHoldButton)
        case buttonLockToggled(RemoteHoldButton)
        case recordTapped
        case setRemoteVisible(Bool)
        #if DEBUG
        case probe([UInt8])
        #endif
    }

    private static func deliver(_ intent: Intent, to central: CameraCentral) async {
        switch intent {
        case .shutterTapped: await central.shutterTapped()
        case .shutterHalfDown: await central.shutterHalfDown()
        case .shutterHalfUp: await central.shutterHalfUp()
        case .shutterFullDown: await central.shutterFullDown()
        case .shutterFullUp: await central.shutterFullUp()
        case .shutterCancelled: await central.shutterGestureCancelled()
        case let .buttonDown(button): await central.buttonDown(button)
        case let .buttonUp(button): await central.buttonUp(button)
        case let .buttonLockToggled(button): await central.buttonLockToggled(button)
        case .recordTapped: await central.recordTapped()
        case let .setRemoteVisible(visible): await central.setRemoteUIVisible(visible)
        #if DEBUG
        case let .probe(bytes): await central.sendProbeCommand(bytes)
        #endif
        }
    }

    public func setShutterMode(_ mode: ShutterMode) {
        shutterMode = mode
        defaults.set(mode.rawValue, forKey: Self.shutterModeKey)
    }

    /// Tap-mode shutter: the safe autonomous capture sequence.
    public func shutterTapped() {
        intents.yield(.shutterTapped)
    }

    public func shutterHalfDown() {
        intents.yield(.shutterHalfDown)
    }

    public func shutterHalfUp() {
        intents.yield(.shutterHalfUp)
    }

    public func shutterFullDown() {
        intents.yield(.shutterFullDown)
    }

    public func shutterFullUp() {
        intents.yield(.shutterFullUp)
    }

    public func shutterCancelled() {
        intents.yield(.shutterCancelled)
    }

    public func buttonDown(_ button: HoldButton) {
        intents.yield(.buttonDown(button.engineButton))
    }

    public func buttonUp(_ button: HoldButton) {
        intents.yield(.buttonUp(button.engineButton))
    }

    public func buttonLockToggled(_ button: HoldButton) {
        intents.yield(.buttonLockToggled(button.engineButton))
    }

    public func recordTapped() {
        intents.yield(.recordTapped)
    }

    /// Drives the RSSI poll from the Remote tab's visibility — no radio reads while the tab isn't on screen.
    public func setRemoteVisible(_ visible: Bool) {
        if !visible { signalBars = nil } // stale bars are worse than none
        intents.yield(.setRemoteVisible(visible))
    }

    #if DEBUG
    // MARK: - Zoom/MF opcode probe (docs/03 🔴 — disputed groups; debug builds only)

    /// Labels for the disputed zoom/MF candidates (group × step), e.g. `"02 44 10"` — indices pair with
    /// ``fireProbe(at:)``. Results are read from the device log (`subsystem:me.congee.alfa`), like the CC10 probe.
    public let probeCandidates: [String] = probeMatrix.map { bytes in
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    /// Labels of probes fired this session, newest first — the panel's local history.
    public private(set) var probeHistory: [String] = []

    private static let probeMatrix: [[UInt8]] = SonyRemoteCommand.ProbeGroup.allCases.flatMap { group in
        [UInt8(0x10), UInt8(0x20)].map { SonyRemoteCommand.probeBytes(group: group, step: $0) }
    }

    /// Fires one disputed candidate at the camera through the same gated FF01 path real buttons use (bypassing the
    /// capture engine — a probe is not a modeled button). Watch the lens/body for what actually moves.
    public func fireProbe(at index: Int) {
        guard Self.probeMatrix.indices.contains(index) else { return }
        let bytes = Self.probeMatrix[index]
        probeHistory.insert(probeCandidates[index], at: 0)
        intents.yield(.probe(bytes))
    }
    #endif

    // MARK: - Event intake (from GeotagCoordinator's single consumption loop)

    func handle(_ event: CameraEvent) {
        switch event {
        case let .remoteControl(state):
            apply(state)
        case let .rssi(dBm):
            signalBars = Self.bars(fromDBm: dBm)
        default:
            break
        }
    }

    private func apply(_ state: RemoteControlState) {
        activity = switch state.activity {
        case .disconnected: .disconnected
        case .connected: .connected
        case .focusing: .focusing
        case .exposing: .exposing
        case .recording: .recording
        }
        remoteFeatureActive = state.remoteFeatureActive
        afOnPhase = Self.phase(state.afOn)
        c1Phase = Self.phase(state.c1)
        isShutterEngaged = state.shutter != .idle
        isRecording = state.isRecording
        recordingStartedAt = state.recordingStartedAt
        if exposureStartedAt != nil, state.exposureStartedAt == nil {
            exposureEndedAt = Date() // the edge the NR-countdown display hangs off
        }
        exposureStartedAt = state.exposureStartedAt
        lastExposureSeconds = state.lastExposureSeconds
        failureDescription = state.lastFailure.map(Self.describe)
        if activity == .disconnected { signalBars = nil }
    }

    private static func phase(_ phase: HeldButtonPhase) -> HoldPhase {
        switch phase {
        case .idle: .idle
        case .held: .held
        case .locked: .locked
        }
    }

    private static func describe(_ failure: RemoteFailure) -> String {
        switch failure {
        case .shutterTimedOut:
            "The camera didn't confirm the shot — try again."
        case .remoteFeatureInactive:
            "The camera's Bluetooth remote-control setting is off — enable it in the camera menu."
        case let .writeFailed(message):
            "Command failed: \(message)"
        }
    }

    /// Conventional dBm → bar buckets (BLE at arm's length is typically −40…−70 dBm).
    private static func bars(fromDBm dBm: Int) -> Int {
        switch dBm {
        case (-55)...: 4
        case (-65)...: 3
        case (-75)...: 2
        case (-85)...: 1
        default: 0
        }
    }
}

private extension RemoteCoordinator.HoldButton {
    var engineButton: RemoteHoldButton {
        switch self {
        case .afOn: .afOn
        case .c1: .c1
        }
    }
}
