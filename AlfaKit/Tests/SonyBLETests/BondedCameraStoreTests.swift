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
        return UserDefaultsBondedCameraStore(defaults: defaults, key: "bondedCamera")
    }

    @Test("Starts empty")
    func startsEmpty() {
        #expect(freshStore(suite: "alfa.test.bond.empty").load() == nil)
    }

    @Test("Round-trips a saved camera (id and name)")
    func roundTrips() {
        let store = freshStore(suite: "alfa.test.bond.roundtrip")
        let camera = RememberedCamera(id: UUID(), name: "ILCE-7RM5")
        store.save(camera)
        #expect(store.load() == camera)
    }

    @Test("Round-trips a camera with no advertised name")
    func roundTripsNoName() {
        let store = freshStore(suite: "alfa.test.bond.noname")
        let camera = RememberedCamera(id: UUID(), name: nil)
        store.save(camera)
        #expect(store.load() == camera)
    }

    @Test("Round-trips the connectsWhilePoweredOff safety-gate flag")
    func roundTripsConnectsWhilePoweredOff() {
        let store = freshStore(suite: "alfa.test.bond.cwpo")
        let camera = RememberedCamera(id: UUID(), name: "ILCE-7RM5", connectsWhilePoweredOff: false)
        store.save(camera)
        #expect(store.load() == camera)
        #expect(store.load()?.connectsWhilePoweredOff == false)
    }

    @Test("Decodes a camera persisted without connectsWhilePoweredOff as unknown (nil)")
    func tolerantDecodeLegacyCamera() {
        let suite = "alfa.test.bond.legacy"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let id = UUID()
        // A blob written by a build predating the field — must still load, with the flag reading nil (unknown).
        let legacy = Data(#"{"id":"\#(id.uuidString)","name":"ILCE-7RM5"}"#.utf8)
        defaults.set(legacy, forKey: "bondedCamera")
        let loaded = UserDefaultsBondedCameraStore(defaults: defaults, key: "bondedCamera").load()
        #expect(loaded?.id == id)
        #expect(loaded?.name == "ILCE-7RM5")
        #expect(loaded?.connectsWhilePoweredOff == nil)
    }

    @Test("Clear forgets the camera")
    func clears() {
        let store = freshStore(suite: "alfa.test.bond.clear")
        store.save(RememberedCamera(id: UUID(), name: "α7R V"))
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("Ignores a corrupt stored value")
    func ignoresCorrupt() {
        let suite = "alfa.test.bond.corrupt"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(Data("not-json".utf8), forKey: "bondedCamera")
        let store = UserDefaultsBondedCameraStore(defaults: defaults, key: "bondedCamera")
        #expect(store.load() == nil)
    }
}
