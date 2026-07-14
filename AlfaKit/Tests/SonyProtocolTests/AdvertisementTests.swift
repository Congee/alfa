import Foundation
import Testing
@testable import SonyProtocol

@Suite("Sony advertisement")
struct AdvertisementTests {
    // Documented example manufacturer data (docs/03-ble-protocol.md):
    // 2d01 0300 6400 4531 22eb00 214000
    private let example: [UInt8] = [
        0x2D, 0x01, 0x03, 0x00, 0x64, 0x00, 0x45, 0x31, 0x22, 0xEB, 0x00, 0x21, 0x40, 0x00,
    ]

    @Test("Parses the documented example")
    func parsesExample() throws {
        let adv = try #require(SonyAdvertisement(manufacturerData: example))
        #expect(adv.protocolVersion == 0x64)
        #expect(adv.modelCode == "E1")
        #expect(adv.statusFlags?.contains(.locationSupported) == true)
        #expect(adv.statusFlags?.contains(.pairingSupported) == true)
    }

    @Test("Rejects non-Sony manufacturer data (Apple company ID)")
    func rejectsNonSony() {
        #expect(SonyAdvertisement(manufacturerData: [0x4C, 0x00, 0x01]) == nil)
    }

    @Test("Does not trap on truncated input")
    func handlesShortInput() {
        #expect(SonyAdvertisement(manufacturerData: [0x2D]) == nil)          // too short for a company ID
        #expect(SonyAdvertisement(manufacturerData: [0x2D, 0x01]) != nil)    // valid Sony, empty payload
    }
}
