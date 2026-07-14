import AlfaGeotag
import SwiftUI

/// First-run (and re-enterable) setup: permissions → camera prep → pair. Drives the coordinator's permission and
/// pairing intents and reflects its observable state; branches only on primitive helpers (no SonyBLE types).
struct OnboardingView: View {
    let coordinator: GeotagCoordinator

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var step: Step = .welcome
    @State private var requestedAlways = false

    private enum Step { case welcome, bluetooth, location, cameraPrep, pair, done }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                content
                Spacer()
                VStack(spacing: 12) { buttons }
            }
            .padding()
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .navigationTitle("Set up Alfa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { finish() }
                }
            }
            .onChange(of: coordinator.isConnected) { _, connected in
                // After a successful pair, escalate to "Always" (per Apple's/Geotag Alpha's guidance).
                if connected, step == .pair, !requestedAlways {
                    requestedAlways = true
                    coordinator.requestLocationAlways()
                }
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            header("location.viewfinder", "Battery-friendly geotagging",
                   "Alfa writes GPS and time into your Sony photos over Bluetooth — and, unlike other apps, backs "
                   + "off cleanly in standby so it doesn't drain your camera battery.")
        case .bluetooth:
            header("dot.radiowaves.left.and.right", "Bluetooth",
                   "Alfa talks to your camera over Bluetooth Low Energy only. It never connects to other devices.")
            statusLine(coordinator.bluetoothDescription, ok: coordinator.isBluetoothReady)
        case .location:
            header("location.fill", "Location",
                   "Choose “While Using the App” for now. After you pair, Alfa asks for “Always” so geotagging keeps "
                   + "working with the screen locked.")
            statusLine(coordinator.locationAccessDescription, ok: coordinator.locationAuthorized)
        case .cameraPrep:
            header("camera.fill", "Prepare your camera", "On the camera, set these three, then continue:")
            checklist
        case .pair:
            header("antenna.radiowaves.left.and.right", "Pair", pairSubtitle)
            if coordinator.isSearching { ProgressView().padding(.top, 4) }
        case .done:
            header("checkmark.seal.fill", "You're all set",
                   "Alfa is geotagging in the background. Lock your phone and shoot — GPS lands in every frame.")
        }
    }

    private var pairSubtitle: String {
        if coordinator.isConnected, let name = coordinator.cameraName { return "Paired with \(name)." }
        if coordinator.isSearching { return "Searching for your camera…" }
        return "Make sure the camera is in pairing mode, then tap Search."
    }

    // MARK: - Step buttons

    @ViewBuilder private var buttons: some View {
        switch step {
        case .welcome:
            primary("Get started") { step = .bluetooth }
        case .bluetooth:
            if coordinator.isBluetoothReady {
                primary("Continue") { step = .location }
            } else if coordinator.canRequestBluetooth {
                primary("Enable Bluetooth") { coordinator.requestBluetooth() }
            } else {
                primary("Open Settings") { openSettings() }
                secondary("Continue anyway") { step = .location }
            }
        case .location:
            if coordinator.locationAuthorized {
                primary("Continue") { step = .cameraPrep }
            } else if coordinator.canRequestLocation {
                primary("Allow location") { coordinator.requestLocationWhenInUse() }
            } else {
                primary("Open Settings") { openSettings() }
                secondary("Continue anyway") { step = .cameraPrep }
            }
        case .cameraPrep:
            primary("My camera is ready") { startPairing() }
        case .pair:
            if coordinator.isConnected {
                primary("Continue") { step = .done }
            } else {
                primary(coordinator.isSearching ? "Searching…" : "Search again") { startPairing() }
                    .disabled(coordinator.isSearching)
                secondary("Skip for now") { step = .done }
            }
        case .done:
            primary("Start geotagging") { finish() }
        }
    }

    // MARK: - Actions

    private func startPairing() {
        step = .pair
        // First time: enable (begins scan → connect → bond). Retry: the sanctioned way out of back-off.
        if coordinator.isEnabled {
            coordinator.syncNow()
        } else {
            coordinator.enable()
        }
    }

    private func finish() {
        coordinator.completeOnboarding()
        dismiss()
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    // MARK: - Building blocks

    private func header(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(title).font(.title.bold())
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
        .padding(.top, 32)
    }

    private func statusLine(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .font(.callout)
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 14) {
            checkItem("Bluetooth: On", "MENU → Network → Bluetooth")
            checkItem("Location Info Link: On", "MENU → Network → Loc. Info. Link Set.")
            checkItem("Cnct. while Power OFF: Off", "MENU → Network → Cnct./PC Remote")
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func checkItem(_ title: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(path).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
    }
}
