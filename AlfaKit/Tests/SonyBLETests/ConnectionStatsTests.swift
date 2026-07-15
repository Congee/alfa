import Foundation
import Testing
@testable import SonyBLE

@Suite("Connection stats")
struct ConnectionStatsTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test("Counts connects, with background arrivals tallied separately")
    func countsConnects() {
        var stats = ConnectionStats()
        stats.recordConnected(foreground: true, now: at(0))
        stats.recordNotConnected(now: at(10))
        stats.recordConnected(foreground: false, now: at(20))
        stats.recordNotConnected(now: at(30))
        stats.recordConnected(foreground: false, now: at(40))
        #expect(stats.connects == 3)
        #expect(stats.backgroundConnects == 2)
    }

    @Test("A repeat connected while a span is open never double-counts")
    func repeatConnectedIgnored() {
        var stats = ConnectionStats()
        stats.recordConnected(foreground: true, now: at(0))
        stats.recordConnected(foreground: false, now: at(5))
        #expect(stats.connects == 1)
        #expect(stats.backgroundConnects == 0)
        #expect(stats.connectedSince == at(0))
    }

    @Test("Accumulates closed spans and adds the live one on read")
    func accumulatesTime() {
        var stats = ConnectionStats()
        stats.recordConnected(foreground: true, now: at(0))
        stats.recordNotConnected(now: at(45))
        #expect(stats.connectedSeconds(asOf: at(100)) == 45)
        stats.recordConnected(foreground: true, now: at(100))
        #expect(stats.connectedSeconds(asOf: at(130)) == 75) // 45 closed + 30 live
    }

    @Test("Disconnect without an open span is a no-op")
    func disconnectWithoutSpan() {
        var stats = ConnectionStats()
        stats.recordNotConnected(now: at(50))
        #expect(stats == ConnectionStats())
    }

    @Test("Store round-trips, dropping a span left open by a terminated process")
    func storeRoundTripDropsOpenSpan() {
        let suite = "alfa.test.stats.roundtrip"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsConnectionStatsStore(defaults: defaults, key: "stats")

        var stats = ConnectionStats()
        stats.recordConnected(foreground: false, now: at(0))
        stats.recordNotConnected(now: at(60))
        stats.recordConnected(foreground: true, now: at(100)) // dies with this span open
        store.save(stats)

        let loaded = store.load()
        #expect(loaded.connects == 2)
        #expect(loaded.backgroundConnects == 1)
        #expect(loaded.accumulatedConnectedSeconds == 60) // the open span's tail is honestly lost
        #expect(loaded.connectedSince == nil)
    }

    @Test("Loads zeros when nothing (or garbage) is stored")
    func loadsZeros() {
        let suite = "alfa.test.stats.empty"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsConnectionStatsStore(defaults: defaults, key: "stats")
        #expect(store.load() == ConnectionStats())
        defaults.set(Data("not-json".utf8), forKey: "stats")
        #expect(store.load() == ConnectionStats())
    }
}
