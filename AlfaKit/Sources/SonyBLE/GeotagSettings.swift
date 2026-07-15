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
    /// Source the CC13 clock write from the latest GNSS fix's timestamp instead of the device clock. Only a fresh
    /// fix is used (a stale timestamp would set the camera slow); until one arrives the write is deferred.
    public var useGPSTime: Bool
    /// Push the freshest position the instant the camera acquires focus (FF02 half-press status), so the shot about
    /// to be taken carries the most accurate location. Listen-only on the camera's remote-status feed; requires the
    /// camera's Bluetooth remote-control setting to be on for the camera to send focus events.
    public var updateOnFocus: Bool
    /// Hold a standing `connect()` after a dropped link so iOS auto-reconnects the camera on its next power-on — even
    /// with the app in the background (state restoration relaunches Alfa to service it). A camera that goes silent
    /// when off ("Cnct. while Power OFF" = Off — the proven, Geotag-Alpha-parity configuration) makes the wait free by
    /// construction; a camera that stays connectable while off is answered but held *dormant* (no writes, no reconnect
    /// churn) until its fw-gated handshake acknowledges on power-on — Alfa adds no traffic there, though the absolute
    /// cost of the held link is pending a field measurement (`docs/08` IT-10). Defaults **on** so background resume
    /// works out of the box; off is the conservative path (foreground / "Sync now" resume only). See `docs/05`.
    public var backgroundResume: Bool

    public init(
        distanceMeters: Double = 25,
        intervalSeconds: TimeInterval = 0,
        syncClock: Bool = true,
        syncTimeZone: Bool = true,
        useGPSTime: Bool = false,
        updateOnFocus: Bool = true,
        backgroundResume: Bool = true
    ) {
        self.distanceMeters = distanceMeters
        self.intervalSeconds = intervalSeconds
        self.syncClock = syncClock
        self.syncTimeZone = syncTimeZone
        self.useGPSTime = useGPSTime
        self.updateOnFocus = updateOnFocus
        self.backgroundResume = backgroundResume
    }

    /// Tolerant decode: any key absent from persisted JSON falls back to its default, so adding a field in a later build
    /// never discards a user's other saved settings (and a partial blob still loads). Encoding stays synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GeotagSettings.default
        distanceMeters = try container.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? defaults.distanceMeters
        intervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .intervalSeconds)
            ?? defaults.intervalSeconds
        syncClock = try container.decodeIfPresent(Bool.self, forKey: .syncClock) ?? defaults.syncClock
        syncTimeZone = try container.decodeIfPresent(Bool.self, forKey: .syncTimeZone) ?? defaults.syncTimeZone
        useGPSTime = try container.decodeIfPresent(Bool.self, forKey: .useGPSTime) ?? defaults.useGPSTime
        updateOnFocus = try container.decodeIfPresent(Bool.self, forKey: .updateOnFocus) ?? defaults.updateOnFocus
        backgroundResume = try container.decodeIfPresent(Bool.self, forKey: .backgroundResume)
            ?? defaults.backgroundResume
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

    /// Marks the one-time `backgroundResume` migration (below) as done for this store's key.
    private var backgroundResumeMigratedKey: String { key + ".bgResumeOnByDefault" }

    /// Returns the stored settings, or the defaults when nothing valid is persisted.
    public func load() -> GeotagSettings {
        guard let data = defaults.data(forKey: key),
              var settings = try? JSONDecoder().decode(GeotagSettings.self, from: data) else {
            defaults.set(true, forKey: backgroundResumeMigratedKey) // fresh store: any later `false` is user intent
            return .default
        }
        // One-time migration: builds before 2026-07-14 defaulted `backgroundResume` to **off** (a superseded safety
        // model), so a persisted `false` from them is almost certainly the stale default, not a user's choice. Reset
        // it to the corrected default exactly once; anything the user sets after this load sticks.
        if !defaults.bool(forKey: backgroundResumeMigratedKey) {
            defaults.set(true, forKey: backgroundResumeMigratedKey)
            if !settings.backgroundResume {
                settings.backgroundResume = true
                save(settings)
            }
        }
        return settings
    }

    public func save(_ settings: GeotagSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
