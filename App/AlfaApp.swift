import SwiftUI

@main
struct AlfaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: appDelegate.coordinator)
        }
        // Drive the engine's foreground/background awareness: in the foreground a dropped link auto-reconnects (so the
        // camera resumes geotagging the moment it powers back on); in the background no standing connect is held.
        // `initial: true` seeds the state at launch (foreground for a normal launch, background for a state-restoration
        // relaunch), since `onChange` otherwise skips the initial value.
        .onChange(of: scenePhase, initial: true) { _, phase in
            appDelegate.coordinator.setForeground(phase == .active)
        }
    }
}
