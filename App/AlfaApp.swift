import SwiftUI

@main
struct AlfaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: appDelegate.coordinator)
        }
        // Drive the engine's foreground/background awareness: foreground reconnects scan and gate on the camera's
        // advertised power state; background reconnects hold a standing connect (kept across backgrounding) so the
        // camera resumes geotagging the moment it powers back on. `initial: true` seeds the state at launch since
        // `onChange` otherwise skips the initial value — but the authoritative launch-time seed lives in the
        // coordinator (read synchronously from UIKit), because on a background relaunch this scene may not exist yet.
        .onChange(of: scenePhase, initial: true) { _, phase in
            appDelegate.coordinator.setForeground(phase == .active)
        }
    }
}
