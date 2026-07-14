import Foundation

/// A parsed Sony camera BLE advertisement (from `CBAdvertisementDataManufacturerDataKey`, which includes the 2-byte
/// company-ID prefix).
///
/// Detection by company ID `0x012D` is ✅ high-confidence. Status-flag bit meanings are 🟡/🔴 (sources disagree — see
/// `docs/03-ble-protocol.md`), so this parser exposes both decoded flags and the raw status bytes, and never traps on
/// malformed input.
public struct SonyAdvertisement: Sendable, Equatable {
    /// Status flags decoded from the `0x22` tag group. Treat as advisory until verified on the A7R V.
    public struct StatusFlags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let pairingSupported = StatusFlags(rawValue: 0x80)
        public static let pairingEnabled = StatusFlags(rawValue: 0x40) // 🔴 may instead mean "paired/bonded"
        public static let locationSupported = StatusFlags(rawValue: 0x20)
        public static let locationEnabled = StatusFlags(rawValue: 0x10)
        public static let remoteEnabled = StatusFlags(rawValue: 0x02)
    }

    /// Power/connectivity flags decoded from the `0x21` tag group. Bit meanings per gethypoxic (2021) + whc2001's
    /// `PROTOCOL_EN.md` (ILCE-7M3, byte-identical), and used operationally by `ekutner/camera-gps-link` to refuse
    /// connecting to an off-but-connectable camera. ✅ **Verified on the A7R V (fw 4.0):** the flags byte reads `0xF0`
    /// powered-on and `0xB0` powered-off — i.e. bit `0x40` (``cameraOn``) tracks the power lever exactly. This is the
    /// discriminator the reconnect gate uses in place of the silent `CC05` characteristic (`docs/05` reconnect crux).
    public struct PowerFlags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let wirelessPowerOnEnabled = PowerFlags(rawValue: 0x80) // "Cnct. while Power OFF" is on
        public static let cameraOn = PowerFlags(rawValue: 0x40)               // camera currently powered on
        public static let wifiHandoverSupported = PowerFlags(rawValue: 0x20)
        public static let wifiHandoverEnabled = PowerFlags(rawValue: 0x10)
    }

    /// BLE protocol version byte (e.g. `0x64` = 100; `0x41` = 65 is the fw ≥3.02 location-gate threshold).
    public let protocolVersion: UInt8
    /// Two-character ASCII model code (e-mount = `"E1"`), when present.
    public let modelCode: String?
    /// Decoded `0x22`-group status flags, when present.
    public let statusFlags: StatusFlags?
    /// Decoded `0x21`-group power/connectivity flags, when present (🟡 offset unverified on the A7R V).
    public let powerFlags: PowerFlags?
    /// The raw `0x21` tag group (`21 <b> <b>`) exactly as advertised, so the on-device log can pin the flags-byte
    /// offset before ``isCameraOn`` is trusted for connection gating.
    public let powerGroupRaw: [UInt8]?
    /// The raw manufacturer-data payload after the company-ID prefix, for diagnostics / on-device verification.
    public let rawPayload: [UInt8]

    /// Whether the camera is advertising as powered-on (`0x21` bit `0x40`). `nil` when the `0x21` group is absent (older
    /// firmware / non-Alpha bodies) — callers treat `nil` as "can't tell, don't block". ✅ Verified on the A7R V.
    public var isCameraOn: Bool? { powerFlags.map { $0.contains(.cameraOn) } }

    /// Whether "Cnct. while Power OFF" is enabled (`0x21` bit `0x80`) — the setting that keeps the camera connectable,
    /// and therefore drain-prone, while off. `nil` when the `0x21` group is absent.
    public var connectsWhilePoweredOff: Bool? { powerFlags.map { $0.contains(.wirelessPowerOnEnabled) } }

    /// Parses manufacturer data. Returns `nil` if the data is not a Sony advertisement.
    public init?(manufacturerData: [UInt8]) {
        // Company ID is little-endian in the first two bytes.
        guard manufacturerData.count >= 2 else { return nil }
        let company = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
        guard company == SonyGATT.sonyCompanyID else { return nil }

        let payload = Array(manufacturerData.dropFirst(2))
        rawPayload = payload

        // Documented layout (offsets are relative to the full manufacturer data, guarded individually):
        //   [4] protocol version, [6..7] model code, [8]=0x22 tag then [9] flags.
        protocolVersion = manufacturerData.count > 4 ? manufacturerData[4] : 0

        if manufacturerData.count > 7,
           let code = String(bytes: manufacturerData[6...7], encoding: .ascii) {
            modelCode = code
        } else {
            modelCode = nil
        }

        // Status/power area: fixed 3-byte TLV groups (`tag b1 b2`) beginning at offset 8. The `0x22` (pairing/location)
        // group is present only when the camera is powered on; `0x21` (power/connectivity) is always present. Both are
        // located by walking the groups rather than a hard-coded index, because the presence of `0x22` shifts `0x21`'s
        // offset (verified on the A7R V: on → `22 … 21 F0 00`, off → `21 B0 02`). The flags byte is the one after the tag.
        if let group = Self.tagGroup(0x22, in: manufacturerData), group.count >= 2 {
            statusFlags = StatusFlags(rawValue: group[1])
        } else {
            statusFlags = nil
        }

        if let group = Self.tagGroup(0x21, in: manufacturerData), group.count >= 2 {
            powerGroupRaw = group
            powerFlags = PowerFlags(rawValue: group[1])
        } else {
            powerGroupRaw = nil
            powerFlags = nil
        }
    }

    /// Walks the fixed 3-byte TLV groups (`tag b1 b2`) from offset 8 and returns the group whose tag matches, or `nil`.
    /// Stepping in threes (rather than a raw byte search) avoids matching a `tag` value that appears inside another
    /// group's payload.
    private static func tagGroup(_ tag: UInt8, in data: [UInt8]) -> [UInt8]? {
        var index = 8
        while index + 2 < data.count {
            if data[index] == tag { return Array(data[index ..< index + 3]) }
            index += 3
        }
        return nil
    }

    /// Convenience for `Data` (CoreBluetooth) callers.
    public init?(manufacturerData data: Data) {
        self.init(manufacturerData: [UInt8](data))
    }
}
