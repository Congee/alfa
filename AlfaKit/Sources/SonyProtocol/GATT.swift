import Foundation

/// Reverse-engineered Sony Alpha BLE GATT map.
///
/// See `docs/03-ble-protocol.md`. UUIDs are exposed as strings so this module stays free of CoreBluetooth; the
/// `SonyBLE` layer converts them to `CBUUID` (which accepts both the 16-bit short form, e.g. `"DD11"`, and the full
/// 128-bit vendor form).
public enum SonyGATT {
    /// Sony Corporation Bluetooth SIG company identifier. On the wire it is little-endian (`2D 01`).
    public static let sonyCompanyID: UInt16 = 0x012D

    /// Vendor service UUIDs (128-bit, pattern `8000XX00-XX00-FFFF-FFFF-FFFFFFFFFFFF`).
    public enum Service {
        public static let location = "8000DD00-DD00-FFFF-FFFF-FFFFFFFFFFFF"
        public static let remoteControl = "8000FF00-FF00-FFFF-FFFF-FFFFFFFFFFFF"
        public static let cameraControl = "8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFF"
        public static let pairing = "8000EE00-EE00-FFFF-FFFF-FFFFFFFFFFFF"
    }

    /// Characteristic UUIDs (16-bit short IDs under the standard Bluetooth base UUID).
    public enum Characteristic {
        // Location service (8000DD00)
        public static let locationWrite = "DD11" // write GPS+time packet
        public static let locationConfig = "DD21" // read config/flags
        public static let locationUnlock = "DD30" // fw >=3.02: write 0x01 to enable endpoint
        public static let locationEnable = "DD31" // fw >=3.02: write 0x01 to enable updates
        public static let locationNotify = "DD01" // notify: location-enabled flag

        // Remote Control service (8000FF00)
        public static let remoteCommand = "FF01" // write command bytes
        public static let remoteStatus = "FF02"  // notify camera status

        // Camera Control service (8000CC00)
        public static let cameraPowerState = "CC05" // power/Wi-Fi state
        public static let cameraTimeSync = "CC13"   // time-sync packet (some bodies)
        public static let cameraBatteryInfo = "CC10" // battery info — UNVERIFIED doc-only lead (docs/03); probe only

        // Pairing service (8000EE00)
        public static let pairingCommand = "EE01"
    }

    /// Standard Client Characteristic Configuration Descriptor (enables notifications).
    public static let cccd = "2902"
}
