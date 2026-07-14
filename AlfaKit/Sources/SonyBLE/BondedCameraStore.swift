import Foundation

/// Persists the identifier of the last successfully-bonded camera so the engine can re-adopt it via
/// `retrievePeripherals(withIdentifiers:)` on a later launch instead of scanning again (a "good BLE citizen" — see
/// `docs/05-battery-strategy.md`). CoreBluetooth peripheral identifiers are stable per host device.
public protocol BondedCameraStore: Sendable {
    /// The last bonded camera's identifier, if one has been remembered.
    func load() -> UUID?
    /// Remembers a successfully-bonded, location-capable camera.
    func save(_ identifier: UUID)
    /// Forgets the remembered camera (e.g. a "Forget camera" action, or after an unpair).
    func clear()
}

/// `UserDefaults`-backed ``BondedCameraStore``. No external dependency.
///
/// `UserDefaults` is documented thread-safe and everything else here is immutable, which is the written justification
/// for `@unchecked Sendable` (the store is handed to the `CameraCentral` actor).
public struct UserDefaultsBondedCameraStore: BondedCameraStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "me.congee.alfa.bondedCameraID") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> UUID? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return UUID(uuidString: raw)
    }

    public func save(_ identifier: UUID) {
        defaults.set(identifier.uuidString, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
