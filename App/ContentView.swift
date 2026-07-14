import AlfaGeotag
import SwiftUI

struct ContentView: View {
    @State private var coordinator = GeotagCoordinator()

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Geotagging", value: coordinator.isEnabled ? "On" : "Off")
                    LabeledContent("Connection", value: coordinator.connectionDescription)
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
        }
    }
}

#Preview {
    ContentView()
}
