import SwiftUI

/// In-app help: battery-drain mitigations, multi-app guidance, camera removal, compatibility, and About.
/// Content mirrors `docs/05-battery-strategy.md` and the pairing guide.
struct HelpView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("If the camera battery drains in standby") {
                    helpRow("Only run one remote app", "Two BLE apps (e.g. Alfa + Sony Creators') fight over the "
                        + "single camera link and cause connect/disconnect churn. This is the biggest single fix — "
                        + "close the others.")
                    helpRow("Turn off “Cnct. while Power OFF”", "MENU → Network → Cnct./PC Remote → set "
                        + "Cnct. while Power OFF to Off. Stops the camera re-advertising in standby.")
                    helpRow("Or use Airplane Mode", "Turning on the camera's Airplane Mode also stops the drain "
                        + "outright when you're not actively geotagging.")
                }

                Section("Camera setup") {
                    helpRow("Bluetooth on", "MENU → Network → Bluetooth → Bluetooth Function: On.")
                    helpRow("Pair", "Put the camera in pairing mode (MENU → Network → Bluetooth → Pairing), then run "
                        + "Set up / pair camera on the Home tab.")
                    helpRow("Location is automatic", "No camera menu toggle is needed — Alfa enables location transfer "
                        + "over Bluetooth itself once it connects.")
                }

                Section("Removing a camera") {
                    Text("Tap Forget camera on the Home tab. To fully remove the pairing, also tap "
                        + "Forget This Device on your iPhone/iPad in Settings → Bluetooth, and delete the phone "
                        + "from MENU → Network → Bluetooth on the camera.")
                        .font(.footnote)
                }

                Section("Compatibility") {
                    Text("Reference body: Sony A7R V (ILCE-7RM5), firmware 4.0 — the model Alfa is validated against. "
                        + "Other current-generation Alpha bodies with Bluetooth location transfer are expected to "
                        + "work but aren't yet verified. Alfa is open source; build from source to try your body.")
                        .font(.footnote)
                }

                Section("About") {
                    Text("Alfa — battery-efficient Bluetooth geotagging for Sony Alpha cameras. Phase 1: geotag core. "
                        + "Not affiliated with Sony. See the docs/ folder for the protocol and battery strategy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Help")
        }
    }

    private func helpRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
