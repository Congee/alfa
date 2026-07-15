import Foundation

/// Running connection diagnostics: how often the camera link was (re)established — and how often that happened with
/// the app in the background, the case that historically failed silently — plus total time spent connected. Persisted
/// so the numbers survive the very relaunches they exist to prove (a background state-restoration relaunch resets all
/// in-memory state). Pure value type; time is injected so it stays host-testable.
public struct ConnectionStats: Sendable, Equatable, Codable {
    /// Times a link reached `.connected` (fresh connects, background auto-resumes, and standby → power-on flips alike).
    public var connects: Int
    /// Subset of ``connects`` that happened while the app was backgrounded — the background auto-resume proof.
    public var backgroundConnects: Int
    /// Connected time accumulated over *closed* spans. A live span is added by ``connectedSeconds(asOf:)``.
    public var accumulatedConnectedSeconds: TimeInterval
    /// Start of the currently-open connected span; nil while not connected.
    public var connectedSince: Date?

    public init(
        connects: Int = 0,
        backgroundConnects: Int = 0,
        accumulatedConnectedSeconds: TimeInterval = 0,
        connectedSince: Date? = nil
    ) {
        self.connects = connects
        self.backgroundConnects = backgroundConnects
        self.accumulatedConnectedSeconds = accumulatedConnectedSeconds
        self.connectedSince = connectedSince
    }

    /// Records a transition into `.connected`. A repeat while a span is already open is ignored (event replays must
    /// not double-count).
    public mutating func recordConnected(foreground: Bool, now: Date) {
        guard connectedSince == nil else { return }
        connects += 1
        if !foreground { backgroundConnects += 1 }
        connectedSince = now
    }

    /// Records leaving `.connected` (disconnect, standby, back-off …): closes the open span into the accumulator.
    public mutating func recordNotConnected(now: Date) {
        guard let since = connectedSince else { return }
        accumulatedConnectedSeconds += max(0, now.timeIntervalSince(since))
        connectedSince = nil
    }

    /// Total connected time: closed spans plus the currently-open one (if any).
    public func connectedSeconds(asOf now: Date) -> TimeInterval {
        accumulatedConnectedSeconds + (connectedSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}

/// Persistence boundary for ``ConnectionStats`` — injectable so the coordinator is host-testable.
public protocol ConnectionStatsStore: Sendable {
    func load() -> ConnectionStats
    func save(_ stats: ConnectionStats)
}

/// `UserDefaults`-backed store (same justification as `UserDefaultsGeotagSettingsStore`: the type holds only the
/// documented-thread-safe defaults handle and an immutable key).
public struct UserDefaultsConnectionStatsStore: ConnectionStatsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "me.congee.alfa.connectionStats") {
        self.defaults = defaults
        self.key = key
    }

    /// Returns the stored stats, or zeros when nothing valid is persisted. A span left open by a terminated process
    /// is dropped rather than guessed at — the link's fate after death is unknown, so the tail is honestly lost
    /// (an undercount, never an overcount).
    public func load() -> ConnectionStats {
        guard let data = defaults.data(forKey: key),
              var stats = try? JSONDecoder().decode(ConnectionStats.self, from: data) else {
            return ConnectionStats()
        }
        stats.connectedSince = nil
        return stats
    }

    public func save(_ stats: ConnectionStats) {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: key)
    }
}
