import Foundation

/// Camera power / standby state, parsed from a `CC05` notification (Camera Control service `8000CC00`).
///
/// This is the signal that lets the Balanced battery policy tear the BLE link down **proactively** when the camera
/// enters standby, rather than only inferring standby after CoreBluetooth eventually reports a disconnect.
///
/// Byte semantics are single-source (alpha-gps RE, medium confidence — see `docs/03-ble-protocol.md`):
/// `04 00 00 00 00` = on, `04 00 00 02 04` = off. Parsing is therefore deliberately conservative: it reports a
/// definitive `.off` (which tears the link down) only for a frame it recognises, and returns `.unknown` for everything
/// else so unmodelled data can never trigger a spurious disconnect.
///
/// Note that `CC05` is silent on the A7R V (`docs/03`), so this is a best-effort signal on bodies that do emit it —
/// the real power discriminator is the advertisement's `0x21` `CameraOn` bit. That asymmetry sets the trade: missing a
/// genuine power-off costs a link held slightly too long, while a false one silently stops geotagging.
public enum CameraPowerState: Sendable, Equatable {
    /// Camera is awake — a BLE link is worth holding for per-shot geotags.
    case on
    /// Camera is powered off / in standby.
    case off
    /// Frame not recognised — make no power-policy decision.
    case unknown

    /// The only two frames anyone has reverse-engineered.
    private static let onFrame: [UInt8] = [0x04, 0x00, 0x00, 0x00, 0x00]
    private static let offFrame: [UInt8] = [0x04, 0x00, 0x00, 0x02, 0x04]

    /// Parses a raw `CC05` notification/read value.
    public init(cc05 bytes: [UInt8]) {
        // Match the documented frames exactly; trailing bytes are tolerated, near-misses are not. `CC05` is
        // "power/**Wi-Fi** state", so an unrecognised frame is at least as likely to be a Wi-Fi transition on a
        // camera that is wide awake — and `.off` is not a cheap guess: it tears the link down and backs off, which
        // stops geotagging until the user foregrounds the app. Short and empty frames fall out here too.
        switch Array(bytes.prefix(5)) {
        case Self.onFrame: self = .on
        case Self.offFrame: self = .off
        default: self = .unknown
        }
    }
}
