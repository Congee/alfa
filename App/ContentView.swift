import AlfaGeotag
import SwiftUI

struct ContentView: View {
    @State private var coordinator: GeotagCoordinator
    @State private var showOnboardingManually = false

    /// The coordinator is created and owned by `AppDelegate` (so it exists for the app-launch state-restoration hook)
    /// and injected here as `@State`'s initial value, keeping a single instance across the view tree.
    init(coordinator: GeotagCoordinator) {
        _coordinator = State(initialValue: coordinator)
    }

    var body: some View {
        TabView {
            HomeView(coordinator: coordinator) { showOnboardingManually = true }
                .tabItem { Label("Home", systemImage: "location.fill") }
            SettingsView(coordinator: coordinator)
                .tabItem { Label("Settings", systemImage: "gearshape") }
            HelpView()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        .task { await coordinator.loadRememberedCameraIfNeeded() }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView(coordinator: coordinator)
        }
    }

    /// Shows onboarding on first launch (until completed) or when re-triggered from Home. Dismissal only resets the
    /// manual trigger; the flow's Done/Skip buttons mark it complete so it won't reappear next launch.
    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !coordinator.hasCompletedOnboarding || showOnboardingManually },
            set: { presented in if !presented { showOnboardingManually = false } }
        )
    }
}

#Preview {
    ContentView(coordinator: GeotagCoordinator())
}
