import Foundation

/// User-tunable geotag preferences, persisted across launches. Distance/interval feed the pure policy; the two
/// time flags feed ``CameraCentral``'s packet construction (tz block) and CC13 clock write.
public struct GeotagSettings: Sendable, Equatable, Codable {
    /// Minimum movement (meters) before pushing a new location while connected.
    public var distanceMeters: Double
    /// Minimum time (seconds) between pushes; `0` disables the interval throttle.
    public var intervalSeconds: TimeInterval
    /// Best-effort CC13 clock sync on connect (beta).
    public var syncClock: Bool
    /// Include the tz/dst block in the location packet (Time Area Correction).
    public var syncTimeZone: Bool

    public init(
        distanceMeters: Double = 25,
        intervalSeconds: TimeInterval = 0,
        syncClock: Bool = true,
        syncTimeZone: Bool = true
    ) {
        self.distanceMeters = distanceMeters
        self.intervalSeconds = intervalSeconds
        self.syncClock = syncClock
        self.syncTimeZone = syncTimeZone
    }

    /// The shipping defaults (match `ConnectionPolicy.balanced`: 25 m, no interval throttle, time sync on).
    public static let `default` = GeotagSettings()

    /// Produces a `ConnectionPolicy` by overriding `base`'s thresholds with these settings, keeping its
    /// connect-behavior flags (stay-connected / back-off).
    public func policy(basedOn base: ConnectionPolicy = .balanced) -> ConnectionPolicy {
        var policy = base
        policy.minimumDistanceMeters = distanceMeters
        policy.minimumIntervalSeconds = intervalSeconds
        return policy
    }
}

/// Persistence boundary for ``GeotagSettings`` — injectable so the coordinator is host-testable.
public protocol GeotagSettingsStore: Sendable {
    func load() -> GeotagSettings
    func save(_ settings: GeotagSettings)
}

/// `UserDefaults`-backed store. `@unchecked Sendable` is justified by `UserDefaults` being documented thread-safe;
/// this type holds only the (immutable) defaults handle and key.
public struct UserDefaultsGeotagSettingsStore: GeotagSettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "me.congee.alfa.settings") {
        self.defaults = defaults
        self.key = key
    }

    /// Returns the stored settings, or the defaults when nothing valid is persisted.
    public func load() -> GeotagSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(GeotagSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: GeotagSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
