import AlfaGeotag
import SwiftUI

/// User-tunable geotag preferences. Every change is persisted and mirrored into the engine immediately via the
/// coordinator's primitive setters (which keep the app layer free of SonyBLE types).
struct SettingsView: View {
    let coordinator: GeotagCoordinator

    private let distances: [Double] = [10, 25, 50, 100]
    private let intervals: [TimeInterval] = [0, 5, 15, 30, 60]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Update distance", selection: distanceBinding) {
                        ForEach(distances, id: \.self) { Text("\(Int($0)) m").tag($0) }
                    }
                    Picker("Minimum interval", selection: intervalBinding) {
                        ForEach(intervals, id: \.self) { interval in
                            Text(interval == 0 ? "Off" : "\(Int(interval)) s").tag(interval)
                        }
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Location is sent only after you move at least this far, and no more often than the "
                        + "interval. Larger values save battery.")
                }

                Section {
                    Toggle("Time Correction", isOn: clockBinding)
                    Toggle("Time Area Correction", isOn: timeZoneBinding)
                } header: {
                    Text("Time sync · beta")
                } footer: {
                    Text("Time Correction syncs the camera clock (via CC13, best-effort — bodies that don't support "
                        + "it ignore it). Time Area Correction sends your time zone with each location. Your camera's "
                        + "own Auto Time Correction / Auto Area Adjust settings decide whether to apply them.")
                }

                #if DEBUG
                Section {
                    Toggle("Freeze location pushes", isOn: freezeBinding)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Debug only. Stops sending location to the camera (real pushes and keep-alives) while still "
                        + "receiving fixes — used to measure how long the camera keeps a fix before it shows "
                        + "\"Location information cannot be obtained\" (test T1). Turn off to confirm the fix recovers "
                        + "without a reconnect (T2).")
                }
                #endif
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Bindings (read the coordinator; write through its primitive setters)

    private var distanceBinding: Binding<Double> {
        Binding(get: { coordinator.distanceMeters }, set: { coordinator.setDistanceMeters($0) })
    }

    private var intervalBinding: Binding<TimeInterval> {
        Binding(get: { coordinator.intervalSeconds }, set: { coordinator.setIntervalSeconds($0) })
    }

    private var clockBinding: Binding<Bool> {
        Binding(get: { coordinator.syncClock }, set: { coordinator.setSyncClock($0) })
    }

    private var timeZoneBinding: Binding<Bool> {
        Binding(get: { coordinator.syncTimeZone }, set: { coordinator.setSyncTimeZone($0) })
    }

    #if DEBUG
    private var freezeBinding: Binding<Bool> {
        Binding(get: { coordinator.pushesFrozen }, set: { coordinator.setPushesFrozen($0) })
    }
    #endif
}
