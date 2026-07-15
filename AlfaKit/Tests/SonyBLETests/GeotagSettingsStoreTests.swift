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

    @Test("Round-trips the backgroundResume flag")
    func roundTripsBackgroundResume() {
        let store = freshStore(suite: "alfa.test.settings.bgresume")
        let settings = GeotagSettings(
            distanceMeters: 25, intervalSeconds: 0, syncClock: true, syncTimeZone: true, backgroundResume: true
        )
        store.save(settings)
        #expect(store.load() == settings)
        #expect(store.load().backgroundResume == true)
    }

    @Test("Defaults backgroundResume on (background auto-resume works out of the box)")
    func backgroundResumeDefaultsOn() {
        #expect(GeotagSettings.default.backgroundResume == true)
    }

    @Test("Decodes older settings without backgroundResume, defaulting it and keeping other fields")
    func tolerantDecodeMissingKey() {
        let suite = "alfa.test.settings.legacy"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // A blob written by a build predating `backgroundResume` — must still load, not reset to defaults.
        let legacy = Data(#"{"distanceMeters":50,"intervalSeconds":15,"syncClock":false,"syncTimeZone":true}"#.utf8)
        defaults.set(legacy, forKey: "settings")
        let loaded = UserDefaultsGeotagSettingsStore(defaults: defaults, key: "settings").load()
        #expect(loaded.distanceMeters == 50)
        #expect(loaded.intervalSeconds == 15)
        #expect(loaded.syncClock == false)
        #expect(loaded.syncTimeZone == true)
        #expect(loaded.backgroundResume == true) // absent key falls back to the (now on) default
    }

    @Test("One-time migration: a stale backgroundResume=false from the default-off era is reset to on")
    func migratesLegacyBackgroundResumeOff() {
        let suite = "alfa.test.settings.bgmigrate"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsGeotagSettingsStore(defaults: defaults, key: "settings")
        // A blob persisted by a build whose default was off: the stored `false` is the stale default, not user intent.
        let stale = Data(
            #"{"distanceMeters":25,"intervalSeconds":0,"syncClock":true,"syncTimeZone":true,"backgroundResume":false}"#
                .utf8
        )
        defaults.set(stale, forKey: "settings")
        #expect(store.load().backgroundResume == true) // migrated on first load
        // After the migration, an explicit user choice sticks.
        var chosen = store.load()
        chosen.backgroundResume = false
        store.save(chosen)
        #expect(store.load().backgroundResume == false)
    }

    @Test("A user turning backgroundResume off on a fresh install is not re-migrated")
    func freshInstallOffChoiceSticks() {
        let suite = "alfa.test.settings.bgfresh"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsGeotagSettingsStore(defaults: defaults, key: "settings")
        #expect(store.load() == .default) // first load (no blob) marks the migration done
        var chosen = GeotagSettings.default
        chosen.backgroundResume = false
        store.save(chosen)
        #expect(store.load().backgroundResume == false)
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
