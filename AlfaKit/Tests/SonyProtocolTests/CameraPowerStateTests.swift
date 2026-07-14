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

    @Test("Any non-zero payload behind a valid tag reads as off")
    func nonZeroPayloadIsOff() {
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x02, 0x00]) == .off)
    }

    @Test("Unrecognised frames are unknown, never a false power-off")
    func unrecognisedIsUnknown() {
        #expect(CameraPowerState(cc05: []) == .unknown)                        // empty
        #expect(CameraPowerState(cc05: [0x04]) == .unknown)                    // too short
        #expect(CameraPowerState(cc05: [0x00, 0x00, 0x00, 0x00, 0x00]) == .unknown) // wrong tag
    }

    @Test("Tolerates longer frames")
    func toleratesTrailingBytes() {
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) == .on)
        #expect(CameraPowerState(cc05: [0x04, 0x00, 0x00, 0x02, 0x04, 0x00, 0x00]) == .off)
    }
}
