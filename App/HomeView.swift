import AlfaGeotag
import SwiftUI

/// The main status + controls screen: connection/permission status, enable/sync, and camera management.
struct HomeView: View {
    let coordinator: GeotagCoordinator
    /// Re-presents the onboarding/pairing flow.
    var onSetUp: () -> Void

    @State private var showForgetConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Geotagging", value: coordinator.isEnabled ? "On" : "Off")
                    LabeledContent("Connection", value: coordinator.connectionDescription)
                    if let camera = coordinator.cameraName {
                        LabeledContent("Camera", value: camera)
                    }
                    LabeledContent("Bluetooth", value: coordinator.bluetoothDescription)
                    LabeledContent("Location access", value: coordinator.locationAccessDescription)
                    LabeledContent("Fixes pushed", value: "\(coordinator.pushCount)")
                    if let connects = coordinator.connectsDescription {
                        LabeledContent("Connections", value: connects)
                    }
                    if let connectedTime = coordinator.connectedTimeDescription {
                        LabeledContent("Time connected", value: connectedTime)
                    }
                    if let fix = coordinator.lastFixDescription {
                        LabeledContent("Last fix", value: fix)
                            .font(.footnote.monospacedDigit())
                    }
                    if let error = coordinator.lastError {
                        LabeledContent("Last error", value: error)
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(coordinator.isEnabled ? "Disable geotagging" : "Enable geotagging") {
                        if coordinator.isEnabled {
                            coordinator.disable()
                        } else {
                            coordinator.enable()
                        }
                    }
                    Button("Sync now") {
                        coordinator.syncNow()
                    }
                    .disabled(!coordinator.isEnabled)
                    Button("Set up / pair camera", action: onSetUp)
                    Button("Forget camera", role: .destructive) {
                        showForgetConfirm = true
                    }
                    .disabled(coordinator.cameraName == nil)
                    .confirmationDialog(
                        "Forget this camera?",
                        isPresented: $showForgetConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Forget camera", role: .destructive) {
                            coordinator.forgetCamera()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Alfa disconnects and stops sending location to this camera until you tap Enable or "
                            + "“Sync now” to reconnect.")
                    }
                } footer: {
                    Text("“Sync now” is the deliberate, low-frequency trigger to reconnect a standby camera — Alfa never "
                        + "holds the link open in the background, which is what drains the camera battery.")
                }
            }
            .navigationTitle("Alfa")
        }
    }
}
