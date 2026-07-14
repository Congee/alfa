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

    @Test("Documented example decodes the 0x21 power group as camera-on")
    func exampleCameraOn() throws {
        let adv = try #require(SonyAdvertisement(manufacturerData: example))
        #expect(adv.powerGroupRaw == [0x21, 0x40, 0x00])
        #expect(adv.isCameraOn == true)                 // 0x21 bit 0x40 set
        #expect(adv.connectsWhilePoweredOff == false)   // 0x21 bit 0x80 clear
    }

    // Real A7R V fw 4.0 captures (docs/05 reconnect crux). Powered-on carries a 0x22 group before 0x21 (flags 0xF0);
    // powered-off drops the 0x22 group and leads with 0x21 (flags 0xB0). Bit 0x40 tracks the power lever.
    private let a7rvPoweredOn: [UInt8] = [
        0x2D, 0x01, 0x03, 0x00, 0x65, 0x00, 0x55, 0x31,
        0x22, 0xBA, 0x00, 0x23, 0x96, 0xAC, 0x21, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
    private let a7rvPoweredOff: [UInt8] = [
        0x2D, 0x01, 0x03, 0x00, 0x65, 0x00, 0x55, 0x31,
        0x21, 0xB0, 0x02, 0x23, 0xB7, 0xAC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    @Test("A7R V powered-on advertisement reads camera-on (0x21 = F0)")
    func a7rvOn() throws {
        let adv = try #require(SonyAdvertisement(manufacturerData: a7rvPoweredOn))
        #expect(adv.protocolVersion == 101)
        #expect(adv.powerGroupRaw == [0x21, 0xF0, 0x00])
        #expect(adv.isCameraOn == true)
        #expect(adv.connectsWhilePoweredOff == true)    // "Cnct. while Power OFF" enabled
        #expect(adv.statusFlags != nil)                 // 0x22 group present only when powered on
    }

    @Test("A7R V powered-off advertisement reads camera-off (0x21 = B0)")
    func a7rvOff() throws {
        let adv = try #require(SonyAdvertisement(manufacturerData: a7rvPoweredOff))
        #expect(adv.powerGroupRaw == [0x21, 0xB0, 0x02])
        #expect(adv.isCameraOn == false)                // 0x21 bit 0x40 clear → the drain state
        #expect(adv.connectsWhilePoweredOff == true)    // still connectable-while-off
        #expect(adv.statusFlags == nil)                 // 0x22 group absent when powered off
    }

    @Test("Absent 0x21 group reads as unknown, never a false camera-off")
    func absentPowerGroupIsUnknown() throws {
        // A minimal Sony advertisement with no status area: the gate must treat this as "can't tell", not "off".
        let adv = try #require(SonyAdvertisement(manufacturerData: [0x2D, 0x01, 0x03, 0x00, 0x64, 0x00]))
        #expect(adv.powerFlags == nil)
        #expect(adv.isCameraOn == nil)
        #expect(adv.connectsWhilePoweredOff == nil)
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
