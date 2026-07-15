import AlfaGeotag
import SwiftUI

struct ContentView: View {
    private enum Tab: Hashable { case home, remote, settings, help }

    @State private var session: CameraSession
    @State private var selectedTab: Tab = .home
    @State private var showOnboardingManually = false
    @Environment(\.scenePhase) private var scenePhase

    /// The session (shared engine + both coordinators) is created and owned by `AppDelegate` (so it exists for the
    /// app-launch state-restoration hook) and injected here as `@State`'s initial value, keeping a single instance
    /// across the view tree.
    init(session: CameraSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(coordinator: session.geotag) { showOnboardingManually = true }
                .tabItem { Label("Home", systemImage: "location.fill") }
                .tag(Tab.home)
            RemoteView(remote: session.remote)
                .tabItem { Label("Remote", systemImage: "camera.shutter.button") }
                .tag(Tab.remote)
            SettingsView(coordinator: session.geotag)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
            HelpView()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
                .tag(Tab.help)
        }
        .task { await session.geotag.loadRememberedCameraIfNeeded() }
        // The RSSI poll runs only while the Remote tab is actually on a lit screen — tab selection and scene phase
        // both gate it, so an idle or backgrounded app never reads RSSI.
        .onChange(of: remoteIsVisible, initial: true) { _, visible in
            session.remote.setRemoteVisible(visible)
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView(coordinator: session.geotag)
        }
        .tint(Theme.accent) // outermost, so presented covers/sheets inherit the α-orange accent too
    }

    private var remoteIsVisible: Bool {
        selectedTab == .remote && scenePhase == .active
    }

    /// Shows onboarding on first launch (until completed) or when re-triggered from Home. Dismissal only resets the
    /// manual trigger; the flow's Done/Skip buttons mark it complete so it won't reappear next launch.
    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !session.geotag.hasCompletedOnboarding || showOnboardingManually },
            set: { presented in if !presented { showOnboardingManually = false } }
        )
    }
}

#Preview {
    ContentView(session: CameraSession())
}
