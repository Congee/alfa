import Foundation

/// Remote-control command bytes written to characteristic `FF01`, and the status notifications received on `FF02`.
///
/// Used from Phase 2 onward (see `docs/02-roadmap.md`). Defined now as pure data. Command bytes are ✅ high-confidence;
/// zoom / manual-focus opcodes are 🔴 and intentionally omitted until verified on the A7R V.
public enum SonyRemoteCommand {
    /// A button models a press/release pair — not a stateless one-shot.
    public struct Button: Sendable, Equatable {
        public let press: [UInt8]
        public let release: [UInt8]

        public init(press: [UInt8], release: [UInt8]) {
            self.press = press
            self.release = release
        }
    }

    /// Half-shutter / autofocus (S1).
    public static let shutterHalf = Button(press: [0x01, 0x07], release: [0x01, 0x06])
    /// Full shutter (S2). Always send after `shutterHalf` — a bare full-press is often ignored.
    public static let shutterFull = Button(press: [0x01, 0x09], release: [0x01, 0x08])
    /// AF-ON button.
    public static let afOn = Button(press: [0x01, 0x15], release: [0x01, 0x14])
    /// C1 custom button.
    public static let c1 = Button(press: [0x01, 0x21], release: [0x01, 0x20])
    /// Video record (toggle). Some bodies act on the release (`01 0E`) alone.
    public static let record = Button(press: [0x01, 0x0F], release: [0x01, 0x0E])
}

/// Camera status decoded from a `FF02` notification (🟡 medium confidence; see `docs/03-ble-protocol.md`).
public enum SonyRemoteStatus: Sendable, Equatable {
    case focusReady
    case focusAcquired
    case focusBusy
    case shutterReady
    case pictureBeingTaken
    case recordingStopped
    case recordingStarted
    case remoteFeatureInactive
    case unknown(rawValue: [UInt8])

    /// Parses a raw `FF02` notification payload.
    public init(rawValue bytes: [UInt8]) {
        switch bytes {
        case [0x02, 0x3F, 0x00]: self = .focusReady
        case [0x02, 0x3F, 0x20]: self = .focusAcquired
        case [0x02, 0x3F, 0x40]: self = .focusBusy
        case [0x02, 0xA0, 0x00]: self = .shutterReady
        case [0x02, 0xA0, 0x20]: self = .pictureBeingTaken
        case [0x02, 0xD5, 0x00]: self = .recordingStopped
        case [0x02, 0xD5, 0x20]: self = .recordingStarted
        case [0x02, 0xC3, 0x00]: self = .remoteFeatureInactive
        default: self = .unknown(rawValue: bytes)
        }
    }
}
