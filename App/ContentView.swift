import AlfaGeotag
import SwiftUI

struct ContentView: View {
    @State private var coordinator = GeotagCoordinator()
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
                    LabeledContent("Location access", value: coordinator.locationAuthorized ? "Granted" : "Not granted")
                    LabeledContent("Fixes pushed", value: "\(coordinator.pushCount)")
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

                Section("About") {
                    Text("Alfa — battery-efficient Bluetooth geotagging for Sony Alpha cameras. Phase 1: geotag core. "
                        + "See the docs/ folder for the protocol and battery strategy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Alfa")
            .task { await coordinator.loadRememberedCameraIfNeeded() }
        }
    }
}

#Preview {
    ContentView()
}
