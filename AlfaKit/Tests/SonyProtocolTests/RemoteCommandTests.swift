import Testing
@testable import SonyProtocol

/// Pins the FF01 command byte pairs and the FF02 status decode against `docs/03-ble-protocol.md` — pure data, but
/// a silent transposition here would misfire real camera buttons, so the table is asserted byte for byte.
@Suite("Remote command bytes")
struct RemoteCommandTests {
    @Test("Button press/release pairs match the documented FF01 table")
    func buttonBytes() {
        #expect(SonyRemoteCommand.shutterHalf.press == [0x01, 0x07])
        #expect(SonyRemoteCommand.shutterHalf.release == [0x01, 0x06])
        #expect(SonyRemoteCommand.shutterFull.press == [0x01, 0x09])
        #expect(SonyRemoteCommand.shutterFull.release == [0x01, 0x08])
        #expect(SonyRemoteCommand.afOn.press == [0x01, 0x15])
        #expect(SonyRemoteCommand.afOn.release == [0x01, 0x14])
        #expect(SonyRemoteCommand.c1.press == [0x01, 0x21])
        #expect(SonyRemoteCommand.c1.release == [0x01, 0x20])
        #expect(SonyRemoteCommand.record.press == [0x01, 0x0F])
        #expect(SonyRemoteCommand.record.release == [0x01, 0x0E])
    }

    @Test("FF02 statuses decode per the documented table")
    func statusDecode() {
        #expect(SonyRemoteStatus(rawValue: [0x02, 0x3F, 0x00]) == .focusReady)
        #expect(SonyRemoteStatus(rawValue: [0x02, 0x3F, 0x20]) == .focusAcquired)
        #expect(SonyRemoteStatus(rawValue: [0x02, 0x3F, 0x40]) == .focusBusy)
        #expect(SonyRemoteStatus(rawValue: [0x02, 0xA0, 0x00]) == .shutterReady)
        #expect(SonyRemoteStatus(rawValue: [0x02, 0xA0, 0x20]) == .pictureBeingTaken)
        #expect(SonyRemoteStatus(rawValue: [0x02, 0xD5, 0x00]) == .recordingStopped)
        #expect(SonyRemoteStatus(rawValue: [0x02, 0xD5, 0x20]) == .recordingStarted)
        #expect(SonyRemoteStatus(rawValue: [0x02, 0xC3, 0x00]) == .remoteFeatureInactive)
    }

    @Test("Unrecognized or malformed FF02 payloads fall back to .unknown, never crash")
    func statusDecodeFallback() {
        #expect(SonyRemoteStatus(rawValue: []) == .unknown(rawValue: []))
        #expect(SonyRemoteStatus(rawValue: [0x02]) == .unknown(rawValue: [0x02]))
        #expect(SonyRemoteStatus(rawValue: [0x02, 0x3F]) == .unknown(rawValue: [0x02, 0x3F]))
        #expect(SonyRemoteStatus(rawValue: [0x02, 0x99, 0x20]) == .unknown(rawValue: [0x02, 0x99, 0x20]))
        #expect(SonyRemoteStatus(rawValue: [0x01, 0x3F, 0x20]) == .unknown(rawValue: [0x01, 0x3F, 0x20]))
    }
}
