import SwiftUI

/// In-app help: battery-drain mitigations, multi-app guidance, camera removal, compatibility, and About.
/// Content mirrors `docs/05-battery-strategy.md` and the pairing guide. Camera menu paths are set in monospace —
/// they are literal breadcrumbs read off the camera's own screen.
struct HelpView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    helpRow("app.connected.to.app.below.fill", "Only run one remote app",
                            "Two BLE apps (e.g. Alfa + Sony Creators') fight over the single camera link and cause "
                            + "connect/disconnect churn. This is the biggest single fix — close the others.")
                    helpRow("power", "Turn off “Cnct. while Power OFF”",
                            "Stops the camera re-advertising in standby.",
                            path: "MENU → Network → Cnct./PC Remote → Cnct. while Power OFF: Off")
                    helpRow("airplane", "Or use Airplane Mode",
                            "Turning on the camera's Airplane Mode also stops the drain outright when you're not "
                            + "actively geotagging.")
                } header: {
                    Text("If the camera battery drains in standby").silkscreen()
                }

                Section {
                    helpRow("dot.radiowaves.left.and.right", "Bluetooth on", nil,
                            path: "MENU → Network → Bluetooth → Bluetooth Function: On")
                    helpRow("link", "Pair",
                            "Put the camera in pairing mode, then run Set up / pair camera on the Home tab.",
                            path: "MENU → Network → Bluetooth → Pairing")
                    helpRow("location.fill", "Location is automatic",
                            "No camera menu toggle is needed — Alfa enables location transfer over Bluetooth itself "
                            + "once it connects.")
                } header: {
                    Text("Camera setup").silkscreen()
                }

                Section {
                    Text("Tap Forget camera on the Home tab. To fully remove the pairing, also tap "
                        + "Forget This Device on your iPhone/iPad in Settings → Bluetooth, and delete the phone "
                        + "from MENU → Network → Bluetooth on the camera.")
                        .font(.footnote)
                } header: {
                    Text("Removing a camera").silkscreen()
                }

                Section {
                    Text("Reference body: Sony A7R V (ILCE-7RM5), firmware 4.0 — the model Alfa is validated against. "
                        + "Other current-generation Alpha bodies with Bluetooth location transfer are expected to "
                        + "work but aren't yet verified. Alfa is open source; build from source to try your body.")
                        .font(.footnote)
                } header: {
                    Text("Compatibility").silkscreen()
                }

                Section {
                    Text("Alfa — battery-efficient Bluetooth geotagging and remote control for Sony Alpha cameras. "
                        + "Not affiliated with Sony. See the docs/ folder for the protocol and battery strategy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About").silkscreen()
                }
            }
            .navigationTitle("Help")
        }
    }

    private func helpRow(_ symbol: String, _ title: String, _ detail: String?, path: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                if let path {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
