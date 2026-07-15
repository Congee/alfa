import Foundation

/// A remembered camera's stable identity: the CoreBluetooth peripheral identifier (stable per host device) plus its
/// advertised name, so the UI can show the camera — the way Alpha Remote does — before it reconnects.
public struct RememberedCamera: Sendable, Equatable, Codable {
    public let id: UUID
    public let name: String?
    /// The camera's "Cnct. while Power OFF" state, as last read from its advertisement (`0x21` bit `0x80`):
    /// `false` = goes radio-silent when powered down (a background standing-connect is drain-safe — it only completes on
    /// a genuine power-on); `true` = keeps advertising while off (a background standing-connect would re-link to and
    /// drain it — declined); `nil` = not yet observed. Persisted so the background-resume safety gate is known even on a
    /// cold, scan-less relaunch.
    public let connectsWhilePoweredOff: Bool?

    public init(id: UUID, name: String?, connectsWhilePoweredOff: Bool? = nil) {
        self.id = id
        self.name = name
        self.connectsWhilePoweredOff = connectsWhilePoweredOff
    }

    /// Tolerant decode so a camera persisted by a build predating `connectsWhilePoweredOff` still loads (the field then
    /// reads `nil` = unknown, which the safety gate treats conservatively — no background standing-connect).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        connectsWhilePoweredOff = try container.decodeIfPresent(Bool.self, forKey: .connectsWhilePoweredOff)
    }
}

/// Persists the last successfully-bonded camera so the engine can re-adopt it via
/// `retrievePeripherals(withIdentifiers:)` on a later launch instead of scanning again (a "good BLE citizen" — see
/// `docs/05-battery-strategy.md`), and so the UI can display the remembered camera while it is disconnected.
public protocol BondedCameraStore: Sendable {
    /// The last bonded camera (id + name), if one has been remembered.
    func load() -> RememberedCamera?
    /// Remembers a successfully-bonded, location-capable camera.
    func save(_ camera: RememberedCamera)
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

    public init(defaults: UserDefaults = .standard, key: String = "me.congee.alfa.bondedCamera") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> RememberedCamera? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RememberedCamera.self, from: data)
    }

    public func save(_ camera: RememberedCamera) {
        guard let data = try? JSONEncoder().encode(camera) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
