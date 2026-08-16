import Foundation
import Testing
@testable import SonyProtocol

@Suite("CC05 camera power state")
struct CameraPowerStateTests {
    @Test("Parses the documented on/off frames")
    func documentedFrames() {
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x00, 0x00]) == .on)
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x02, 0x04]) == .off)
    }

    @Test("A near-miss of the off frame is unknown, not off")
    func nearMissIsNotOff() {
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x02, 0x00]) == .unknown)
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x00, 0x04]) == .unknown)
        #expect(CameraPowerState(cc05: [0x04, 0x01, 0x00, 0x00, 0x00]) == .unknown)
    }

    @Test("A Wi-Fi frame on an awake camera never reads as a power-off")
    func wifiFrameIsNotAPowerOff() {
        // CC05 is "power/Wi-Fi state": some other traffic on this characteristic must not stop geotagging.
        for payload in [0x01, 0x02, 0x03, 0x10, 0x20, 0xFF] as [UInt8] {
            #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x00, payload]) != .off)
            #expect(CameraPowerState(cc05: [0x04, payload, 0x00, 0x00, 0x00]) != .off)
        }
    }

    @Test("Unrecognised frames are unknown, never a false power-off")
    func unrecognisedIsUnknown() {
        #expect(CameraPowerState(cc05: []) == .unknown)                        // empty
        #expect(CameraPowerState(cc05: [0x04]) == .unknown)                    // too short
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x02]) == .unknown)  // off frame, truncated
        #expect(CameraPowerState(cc05: [0x00, 0x00, 0x00, 0x00, 0x00]) == .unknown) // wrong tag
    }

    @Test("Tolerates longer frames")
    func toleratesTrailingBytes() {
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) == .on)
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x02, 0x04, 0x00, 0x00]) == .off)
    }
}
