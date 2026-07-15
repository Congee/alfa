import Foundation
import SonyBLE

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

    init(central: CameraCentral, defaults: UserDefaults = .standard) {
        self.central = central
        self.defaults = defaults
        shutterMode = defaults.string(forKey: Self.shutterModeKey).flatMap(ShutterMode.init(rawValue:)) ?? .tapAuto
    }

    // MARK: - Intents

    public func setShutterMode(_ mode: ShutterMode) {
        shutterMode = mode
        defaults.set(mode.rawValue, forKey: Self.shutterModeKey)
    }

    /// Tap-mode shutter: the safe autonomous capture sequence.
    public func shutterTapped() {
        Task { await central.shutterTapped() }
    }

    public func shutterHalfDown() {
        Task { await central.shutterHalfDown() }
    }

    public func shutterHalfUp() {
        Task { await central.shutterHalfUp() }
    }

    public func shutterFullDown() {
        Task { await central.shutterFullDown() }
    }

    public func shutterFullUp() {
        Task { await central.shutterFullUp() }
    }

    public func shutterCancelled() {
        Task { await central.shutterGestureCancelled() }
    }

    public func buttonDown(_ button: HoldButton) {
        Task { await central.buttonDown(button.engineButton) }
    }

    public func buttonUp(_ button: HoldButton) {
        Task { await central.buttonUp(button.engineButton) }
    }

    public func buttonLockToggled(_ button: HoldButton) {
        Task { await central.buttonLockToggled(button.engineButton) }
    }

    public func recordTapped() {
        Task { await central.recordTapped() }
    }

    /// Drives the RSSI poll from the Remote tab's visibility — no radio reads while the tab isn't on screen.
    public func setRemoteVisible(_ visible: Bool) {
        if !visible { signalBars = nil } // stale bars are worse than none
        Task { await central.setRemoteUIVisible(visible) }
    }

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
