import Foundation
import Testing
@testable import SonyBLE

@Suite("Bonded camera store")
struct BondedCameraStoreTests {
    /// Builds a store over an isolated, freshly-cleared defaults suite so each test owns its persistence boundary and
    /// never touches the app's real defaults.
    private func freshStore(suite: String) -> UserDefaultsBondedCameraStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UserDefaultsBondedCameraStore(defaults: defaults, key: "bondedCameraID")
    }

    @Test("Starts empty")
    func startsEmpty() {
        #expect(freshStore(suite: "alfa.test.bond.empty").load() == nil)
    }

    @Test("Round-trips a saved identifier")
    func roundTrips() {
        let store = freshStore(suite: "alfa.test.bond.roundtrip")
        let id = UUID()
        store.save(id)
        #expect(store.load() == id)
    }

    @Test("Clear forgets the identifier")
    func clears() {
        let store = freshStore(suite: "alfa.test.bond.clear")
        store.save(UUID())
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("Ignores a corrupt stored value")
    func ignoresCorrupt() {
        let suite = "alfa.test.bond.corrupt"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("not-a-uuid", forKey: "bondedCameraID")
        let store = UserDefaultsBondedCameraStore(defaults: defaults, key: "bondedCameraID")
        #expect(store.load() == nil)
    }
}
