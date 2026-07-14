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
