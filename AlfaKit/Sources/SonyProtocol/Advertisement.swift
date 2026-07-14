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

    /// BLE protocol version byte (e.g. `0x64` = 100; `0x41` = 65 is the fw ≥3.02 location-gate threshold).
    public let protocolVersion: UInt8
    /// Two-character ASCII model code (e-mount = `"E1"`), when present.
    public let modelCode: String?
    /// Decoded `0x22`-group status flags, when present.
    public let statusFlags: StatusFlags?
    /// The raw manufacturer-data payload after the company-ID prefix, for diagnostics / on-device verification.
    public let rawPayload: [UInt8]

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

        if manufacturerData.count > 9, manufacturerData[8] == 0x22 {
            statusFlags = StatusFlags(rawValue: manufacturerData[9])
        } else {
            statusFlags = nil
        }
    }

    /// Convenience for `Data` (CoreBluetooth) callers.
    public init?(manufacturerData data: Data) {
        self.init(manufacturerData: [UInt8](data))
    }
}
