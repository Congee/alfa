import AlfaGeotag
import SwiftUI

struct ContentView: View {
    @State private var coordinator = GeotagCoordinator()

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Geotagging", value: coordinator.isEnabled ? "On" : "Off")
                }
                Section {
                    Button(coordinator.isEnabled ? "Disable geotagging" : "Enable geotagging") {
                        if coordinator.isEnabled {
                            coordinator.disable()
                        } else {
                            coordinator.enable()
                        }
                    }
                }
                Section("About") {
                    Text("Alfa — battery-efficient Bluetooth geotagging for Sony Alpha cameras. "
                        + "Phase 1 is under construction; see the docs/ folder.")
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
