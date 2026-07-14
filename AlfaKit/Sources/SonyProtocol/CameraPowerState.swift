import Foundation

/// Camera power / standby state, parsed from a `CC05` notification (Camera Control service `8000CC00`).
///
/// This is the signal that lets the Balanced battery policy tear the BLE link down **proactively** when the camera
/// enters standby, rather than only inferring standby after CoreBluetooth eventually reports a disconnect.
///
/// Byte semantics are single-source (alpha-gps RE, medium confidence — see `docs/03-ble-protocol.md`):
/// `04 00 00 00 00` = on, `04 00 00 02 04` = off. Parsing is therefore deliberately conservative: it reports a
/// definitive `.off` (which tears the link down) only for a well-formed frame, and returns `.unknown` for anything it
/// does not recognise so malformed data can never trigger a spurious disconnect.
public enum CameraPowerState: Sendable, Equatable {
    /// Camera is awake — a BLE link is worth holding for per-shot geotags.
    case on
    /// Camera is powered off / in standby.
    case off
    /// Frame not recognised — make no power-policy decision.
    case unknown

    /// Parses a raw `CC05` notification/read value.
    public init(cc05 bytes: [UInt8]) {
        // Every known frame is a `0x04`-tagged, ≥5-byte block; anything else is not a power-state frame we understand.
        guard bytes.first == 0x04, bytes.count >= 5 else {
            self = .unknown
            return
        }
        // In the documented frames the state lives in the payload: an all-zero payload ⇒ on, otherwise ⇒ off.
        self = bytes.dropFirst().allSatisfy { $0 == 0 } ? .on : .off
    }
}
