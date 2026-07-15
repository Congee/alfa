import AlfaGeotag
import MapKit
import SwiftUI

/// The geotagging status + controls screen. Status lives on the "top plate" — a piece of the camera's own dark
/// chrome set into the adaptive screen (the same ``CameraBody`` palette as the Remote tab), the way an LCD sits in
/// a body's top plate — while actions and the map keep the honest List idiom.
struct HomeView: View {
    let coordinator: GeotagCoordinator
    /// Re-presents the onboarding/pairing flow.
    var onSetUp: () -> Void

    @State private var showForgetConfirm = false
    /// `.automatic` frames the marker and keeps following it as pushes land, until the user pans/zooms away.
    @State private var mapPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusPlate(coordinator: coordinator)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                attentionSection
                mapSection
                actionsSection
            }
            .navigationTitle("Alfa")
        }
    }

    /// Access problems only — when Bluetooth and Location are healthy this section disappears entirely, so its
    /// presence *is* the signal.
    @ViewBuilder private var attentionSection: some View {
        if !coordinator.isBluetoothReady || !coordinator.locationIsAlways {
            Section {
                if !coordinator.isBluetoothReady {
                    LabeledContent("Bluetooth", value: coordinator.bluetoothDescription)
                }
                if !coordinator.locationIsAlways {
                    LabeledContent("Location access", value: coordinator.locationAccessDescription)
                }
            } header: {
                Text("Needs attention").silkscreen()
            } footer: {
                if coordinator.isBluetoothReady, coordinator.locationAuthorized, !coordinator.locationIsAlways {
                    Text("Background geotagging needs “Always” location access — Alfa asks for it after pairing, "
                        + "or grant it in Settings.")
                }
            }
        }
    }

    @ViewBuilder private var mapSection: some View {
        if let coordinate = coordinator.lastPushedCoordinate {
            Section {
                Map(position: $mapPosition) {
                    Marker("Camera", systemImage: "camera.fill", coordinate: coordinate)
                        .tint(Theme.accent)
                }
                .frame(height: 220)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Camera location").silkscreen()
            } footer: {
                Text("The last position sent to the camera — what its next photo will be tagged with.")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                if coordinator.isEnabled {
                    coordinator.disable()
                } else {
                    coordinator.enable()
                }
            } label: {
                Text(coordinator.isEnabled ? "Disable geotagging" : "Enable geotagging")
                    .fontWeight(.semibold)
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
}

// MARK: - The top plate (signature element: the camera's chrome set into the screen)

/// The status display: state word in the tracked-capitals voice shared with the Remote banner, the paired body,
/// and LCD-style monospaced readouts. Always dark — this is the camera's surface, not the app's.
private struct StatusPlate: View {
    let coordinator: GeotagCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(toneColor)
                    .frame(width: 8, height: 8)
                Text(coordinator.statusWord)
                    .silkscreen(.subheadline)
                    .foregroundStyle(CameraBody.text)
                Spacer()
                if coordinator.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .tint(CameraBody.label)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.footnote)
                    .foregroundStyle(CameraBody.label)
                Text(coordinator.cameraName ?? "No camera paired")
                    .font(.callout)
                    .foregroundStyle(coordinator.cameraName == nil ? CameraBody.label : CameraBody.text)
            }

            VStack(alignment: .leading, spacing: 6) {
                readout("Fixes pushed", "\(coordinator.pushCount)")
                if let connects = coordinator.connectsDescription {
                    readout("Connections", connects)
                }
                if let time = coordinator.connectedTimeDescription {
                    readout("Time linked", time)
                }
                if let fix = coordinator.lastFixDescription {
                    readout("Last fix", fix)
                }
            }

            if let error = coordinator.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(CameraBody.alphaOrange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(CameraBody.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CameraBody.controlEdge, lineWidth: 1))
        .environment(\.colorScheme, .dark) // camera chrome — dark in any system theme
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .silkscreen(.caption2)
                .foregroundStyle(CameraBody.label)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(CameraBody.text)
                .multilineTextAlignment(.trailing)
        }
    }

    private var toneColor: Color {
        switch coordinator.statusTone {
        case .off, .standby: CameraBody.label
        case .active: CameraBody.okGreen
        case .busy, .attention: CameraBody.alphaOrange
        }
    }
}
