import Foundation
import Testing
@testable import SonyBLE

@Suite("Geotag settings store")
struct GeotagSettingsStoreTests {
    /// Builds a store over an isolated, freshly-cleared defaults suite so each test owns its persistence boundary.
    private func freshStore(suite: String) -> UserDefaultsGeotagSettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UserDefaultsGeotagSettingsStore(defaults: defaults, key: "settings")
    }

    @Test("Loads defaults when nothing is stored")
    func loadsDefaults() {
        #expect(freshStore(suite: "alfa.test.settings.empty").load() == .default)
    }

    @Test("Round-trips saved settings")
    func roundTrips() {
        let store = freshStore(suite: "alfa.test.settings.roundtrip")
        let settings = GeotagSettings(distanceMeters: 50, intervalSeconds: 15, syncClock: false, syncTimeZone: true)
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test("Ignores a corrupt stored value and returns defaults")
    func ignoresCorrupt() {
        let suite = "alfa.test.settings.corrupt"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(Data("not-json".utf8), forKey: "settings")
        let store = UserDefaultsGeotagSettingsStore(defaults: defaults, key: "settings")
        #expect(store.load() == .default)
    }

    @Test("Settings produce a policy that overrides thresholds but keeps connect behavior")
    func policyFromSettings() {
        let settings = GeotagSettings(distanceMeters: 100, intervalSeconds: 60)
        let policy = settings.policy()
        #expect(policy.minimumDistanceMeters == 100)
        #expect(policy.minimumIntervalSeconds == 60)
        #expect(policy.stayConnectedWhileCameraOn == ConnectionPolicy.balanced.stayConnectedWhileCameraOn)
        #expect(policy.backOffInStandby == ConnectionPolicy.balanced.backOffInStandby)
    }
}
