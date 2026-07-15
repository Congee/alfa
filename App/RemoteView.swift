import AlfaGeotag
import SwiftUI

/// The remote-control surface (Phase 2). Deliberately styled as the camera's own control plane — always-dark
/// magnesium-body surface, silkscreen-style button labels, the α-orange mount ring as the shutter — rather than the
/// stock List idiom the rest of the app uses: this is the one screen operated eyes-half-off in the field.
struct RemoteView: View {
    @Bindable var remote: RemoteCoordinator

    var body: some View {
        VStack(spacing: 0) {
            StateBanner(remote: remote)
                .padding(.top, 24)
                .padding(.horizontal, 24)

            Spacer(minLength: 12)

            ShutterControl(remote: remote)

            Spacer(minLength: 12)

            HStack(spacing: 16) {
                HoldButtonView(label: "AF-ON", phase: remote.afOnPhase, isEnabled: controlsEnabled) {
                    remote.buttonDown(.afOn)
                } onUp: {
                    remote.buttonUp(.afOn)
                } onLockToggle: {
                    remote.buttonLockToggled(.afOn)
                }
                HoldButtonView(label: "C1", phase: remote.c1Phase, isEnabled: controlsEnabled) {
                    remote.buttonDown(.c1)
                } onUp: {
                    remote.buttonUp(.c1)
                } onLockToggle: {
                    remote.buttonLockToggled(.c1)
                }
            }
            .padding(.horizontal, 32)

            RecordButton(remote: remote, isEnabled: controlsEnabled)
                .padding(.top, 20)

            Spacer(minLength: 16)

            modePicker
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CameraBody.surface)
        .environment(\.colorScheme, .dark) // the camera body is black in any system theme
        .disabled(false) // individual controls gate themselves so the banner/hints stay interactive
    }

    private var controlsEnabled: Bool {
        remote.activity != .disconnected && remote.remoteFeatureActive
    }

    private var modePicker: some View {
        Picker("Shutter mode", selection: Binding(
            get: { remote.shutterMode },
            set: { remote.setShutterMode($0) }
        )) {
            Text("Tap").tag(RemoteCoordinator.ShutterMode.tapAuto)
            Text("Two-stage").tag(RemoteCoordinator.ShutterMode.twoStage)
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Camera-body palette (deliberate constants — this surface does not adapt to the system theme)

private enum CameraBody {
    static let surface = Color(red: 0.063, green: 0.067, blue: 0.071)      // matte magnesium
    static let control = Color(red: 0.110, green: 0.118, blue: 0.125)      // raised button face
    static let controlEdge = Color.white.opacity(0.08)
    static let label = Color(red: 0.604, green: 0.620, blue: 0.639)        // silkscreen gray
    static let text = Color(red: 0.949, green: 0.949, blue: 0.949)
    static let alphaOrange = Color(red: 0.890, green: 0.447, blue: 0.133)  // the α mount ring
    static let recRed = Color(red: 0.898, green: 0.282, blue: 0.302)       // reserved for recording
    static let okGreen = Color(red: 0.388, green: 0.757, blue: 0.455)
}

// MARK: - State banner (activity word + signal bars + timers + failure line)

private struct StateBanner: View {
    let remote: RemoteCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(stateWord)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(CameraBody.text)
                Spacer()
                SignalBars(bars: remote.signalBars)
            }
            timerLine
            if let failure = remote.failureDescription {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(CameraBody.alphaOrange)
            } else if remote.activity == .disconnected {
                Text("Connect on the Home tab to use the remote.")
                    .font(.footnote)
                    .foregroundStyle(CameraBody.label)
            }
        }
    }

    /// The elapsed line while exposing/recording, and the transient NR-estimate countdown after a long exposure.
    @ViewBuilder private var timerLine: some View {
        if let startedAt = remote.exposureStartedAt {
            elapsed("EXP", since: startedAt, color: CameraBody.text)
        } else if let startedAt = remote.recordingStartedAt {
            elapsed("REC", since: startedAt, color: CameraBody.recRed)
        } else if let endedAt = remote.exposureEndedAt,
                  let seconds = remote.lastExposureSeconds, seconds >= 1 {
            // In-camera long-exposure NR runs a second, dark exposure about as long as the first — the protocol
            // gives no signal for it, so this countdown is an estimate anchored to the observed duration.
            let deadline = endedAt.addingTimeInterval(seconds)
            TimelineView(.periodic(from: endedAt, by: 1)) { context in
                if context.date < deadline {
                    HStack(spacing: 6) {
                        Text("NR")
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(CameraBody.label)
                        Text(timerInterval: context.date...deadline, countsDown: true)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(CameraBody.label)
                        Text("est. noise reduction")
                            .font(.footnote)
                            .foregroundStyle(CameraBody.label)
                    }
                }
            }
        }
    }

    private func elapsed(_ tag: String, since date: Date, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(tag)
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(date, style: .timer)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private var stateWord: String {
        switch remote.activity {
        case .disconnected: "NOT CONNECTED"
        case .connected: "READY"
        case .focusing: "FOCUSING"
        case .exposing: "EXPOSING"
        case .recording: "RECORDING"
        }
    }

    private var stateColor: Color {
        switch remote.activity {
        case .disconnected: CameraBody.label
        case .connected: CameraBody.okGreen
        case .focusing: CameraBody.alphaOrange
        case .exposing: CameraBody.text
        case .recording: CameraBody.recRed
        }
    }
}

private struct SignalBars: View {
    let bars: Int? // 0–4; nil = no reading (hidden)

    var body: some View {
        if let bars {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < bars ? CameraBody.text : CameraBody.controlEdge)
                        .frame(width: 3, height: 5 + CGFloat(index) * 3)
                }
            }
            .accessibilityLabel("Signal \(bars) of 4")
        }
    }
}

// MARK: - The shutter (signature element: the α mount ring)

private struct ShutterControl: View {
    let remote: RemoteCoordinator

    // Tap-mode gesture state: touch-down starts a hold timer; a quick lift is a tap (auto sequence), a long hold
    // sustains the half-press until lift.
    @State private var holdTask: Task<Void, Never>?
    @State private var isPressed = false
    @State private var halfHeld = false
    // Two-stage mode: zone-held flags — a center-only release must also release half (no finger left on S1).
    @State private var ringHeld = false
    @State private var centerHeld = false
    @State private var fireCount = 0 // sensory-feedback trigger

    private static let holdThreshold: Duration = .milliseconds(350)

    var body: some View {
        ZStack {
            ring
            if remote.shutterMode == .twoStage {
                twoStageZones
            } else {
                tapSurface
            }
        }
        .frame(width: 190, height: 190)
        .opacity(enabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.15), value: ringColor)
        .scaleEffect(isPressed || remote.isShutterEngaged ? 0.97 : 1)
        .animation(.easeOut(duration: 0.1), value: isPressed)
        .sensoryFeedback(.impact(weight: .medium), trigger: fireCount)
        .accessibilityLabel(remote.shutterMode == .twoStage ? "Shutter, ring focuses, center fires" : "Shutter")
    }

    private var enabled: Bool { remote.activity != .disconnected && remote.remoteFeatureActive }

    /// The mount ring: its color *is* the capture state — dim at rest, orange while focusing, white while exposing.
    private var ring: some View {
        Circle()
            .strokeBorder(ringColor, lineWidth: 5)
            .background(Circle().fill(CameraBody.control))
    }

    private var ringColor: Color {
        switch remote.activity {
        case .exposing: CameraBody.text
        case .focusing: CameraBody.alphaOrange
        default: CameraBody.alphaOrange.opacity(remote.isShutterEngaged ? 1 : 0.45)
        }
    }

    /// Tap mode: one surface — tap runs the auto sequence, holding sustains a half-press.
    private var tapSurface: some View {
        Circle()
            .fill(.clear)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, !isPressed else { return }
                        isPressed = true
                        holdTask = Task {
                            try? await Task.sleep(for: Self.holdThreshold)
                            guard !Task.isCancelled else { return }
                            halfHeld = true
                            remote.shutterHalfDown()
                        }
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        holdTask?.cancel()
                        holdTask = nil
                        if halfHeld {
                            remote.shutterHalfUp()
                        } else if enabled {
                            fireCount += 1
                            remote.shutterTapped()
                        }
                        halfHeld = false
                        isPressed = false
                    }
            )
    }

    /// Two-stage mode: concentric zones mirroring a physical two-stage button — the ring is S1 (half, focus),
    /// the center is S2 (full; hold it for bulb). Pressing the center alone half-presses first (the engine orders
    /// it), and releasing it with no finger on the ring releases both stages.
    private var twoStageZones: some View {
        ZStack {
            // S1: the ring zone (donut) — annotate with a subtle inner boundary.
            Circle()
                .fill(.clear)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard enabled, !ringHeld else { return }
                            ringHeld = true
                            isPressed = true
                            remote.shutterHalfDown()
                        }
                        .onEnded { _ in
                            guard ringHeld else { return }
                            ringHeld = false
                            isPressed = false
                            remote.shutterHalfUp()
                        }
                )

            Circle()
                .fill(CameraBody.surface)
                .overlay(Circle().strokeBorder(CameraBody.controlEdge, lineWidth: 1))
                .frame(width: 104, height: 104)
                .overlay {
                    Text("S2")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(CameraBody.label)
                }
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard enabled, !centerHeld else { return }
                            centerHeld = true
                            isPressed = true
                            fireCount += 1
                            remote.shutterFullDown()
                        }
                        .onEnded { _ in
                            guard centerHeld else { return }
                            centerHeld = false
                            remote.shutterFullUp()
                            if !ringHeld {
                                isPressed = false
                                remote.shutterHalfUp() // no finger left on S1 — release through
                            }
                        }
                )
        }
    }
}

// MARK: - Hold buttons (AF-ON / C1): press to hold, long-press to lock, tap to unlock

private struct HoldButtonView: View {
    let label: String
    let phase: RemoteCoordinator.HoldPhase
    let isEnabled: Bool
    let onDown: () -> Void
    let onUp: () -> Void
    let onLockToggle: () -> Void

    @State private var pressing = false
    @State private var lockTask: Task<Void, Never>?
    @State private var lockCount = 0 // sensory-feedback trigger

    private static let lockThreshold: Duration = .milliseconds(800)

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .tracking(2)
                .foregroundStyle(active ? CameraBody.surface : CameraBody.text)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(active ? CameraBody.alphaOrange : CameraBody.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(CameraBody.controlEdge, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if phase == .locked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(CameraBody.surface)
                            .padding(6)
                    }
                }
                .scaleEffect(pressing ? 0.96 : 1)
                .animation(.easeOut(duration: 0.1), value: pressing)
            Text(phase == .locked ? "Tap to unlock" : "Hold · long-press locks")
                .font(.caption2)
                .foregroundStyle(CameraBody.label)
        }
        .opacity(isEnabled ? 1 : 0.35)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, !pressing else { return }
                    pressing = true
                    if phase == .locked { return } // the lift will unlock
                    onDown()
                    lockTask = Task {
                        try? await Task.sleep(for: Self.lockThreshold)
                        guard !Task.isCancelled else { return }
                        lockCount += 1
                        onLockToggle() // latches the already-sent press (engine: held → locked)
                    }
                }
                .onEnded { _ in
                    guard pressing else { return }
                    pressing = false
                    lockTask?.cancel()
                    lockTask = nil
                    if phase == .locked {
                        onLockToggle() // tap on a locked button unlocks (sends the release)
                    } else {
                        onUp() // ignored by the engine if the lock latched during the hold
                    }
                }
        )
        .sensoryFeedback(.impact(weight: .heavy), trigger: lockCount)
        .accessibilityLabel(label)
        .accessibilityHint(phase == .locked ? "Locked. Tap to release." : "Hold to press. Long-press to lock.")
    }

    private var active: Bool { phase != .idle }
}

// MARK: - Record

private struct RecordButton: View {
    let remote: RemoteCoordinator
    let isEnabled: Bool

    var body: some View {
        Button {
            remote.recordTapped()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(CameraBody.recRed)
                    .frame(width: 10, height: 10)
                    .opacity(remote.isRecording ? 1 : 0.7)
                Text(remote.isRecording ? "STOP" : "REC")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(remote.isRecording ? CameraBody.text : CameraBody.label)
            }
            .padding(.horizontal, 22)
            .frame(height: 44)
            .background(
                Capsule().fill(remote.isRecording ? CameraBody.recRed.opacity(0.25) : CameraBody.control)
            )
            .overlay(
                Capsule().strokeBorder(
                    remote.isRecording ? CameraBody.recRed : CameraBody.controlEdge, lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .sensoryFeedback(.impact(weight: .light), trigger: remote.isRecording)
        .accessibilityLabel(remote.isRecording ? "Stop recording" : "Start recording")
    }
}
