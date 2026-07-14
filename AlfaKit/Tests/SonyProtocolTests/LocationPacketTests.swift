import Foundation
import Testing
@testable import SonyProtocol

@Suite("Sony location packet")
struct LocationPacketTests {
    @Test("Latitude scales to the documented int32 (worked example)")
    func latitudeWorkedExample() {
        // 20.077731° × 10^7 = 200_777_310 = 0x0BF79E5E  (docs/03-ble-protocol.md)
        #expect(SonyLocationPacket.scaledDegrees(20.077731) == 200_777_310)
        #expect(SonyLocationPacket.int32BE(200_777_310) == [0x0B, 0xF7, 0x9E, 0x5E])
    }

    @Test("Negative coordinates use two's-complement big-endian")
    func negativeCoordinate() {
        let scaled = SonyLocationPacket.scaledDegrees(-122.4194)
        #expect(scaled == -1_224_194_000)
        let be = SonyLocationPacket.int32BE(scaled)
        let restored = Int32(bitPattern:
            (UInt32(be[0]) << 24) | (UInt32(be[1]) << 16) | (UInt32(be[2]) << 8) | UInt32(be[3]))
        #expect(restored == scaled)
    }

    @Test("Full 95-byte packet with timezone matches the documented layout")
    func fullPacketWithTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(
            year: 2026, month: 7, day: 14, hour: 12, minute: 34, second: 56))!
        // Asia/Singapore is a fixed UTC+8 with no DST.
        let packet = SonyLocationPacket(
            latitude: 20.077731, longitude: 139.6917, date: date,
            timeZone: TimeZone(identifier: "Asia/Singapore")!)
        let bytes = packet.encoded()

        #expect(bytes.count == 95)
        #expect(Array(bytes[0...1]) == [0x00, 0x5D])              // length = 93
        #expect(Array(bytes[2...4]) == [0x08, 0x02, 0xFC])        // fixed
        #expect(bytes[5] == 0x03)                                 // tz/dst present
        #expect(Array(bytes[6...10]) == [0x00, 0x00, 0x10, 0x10, 0x10])
        #expect(Array(bytes[11...14]) == [0x0B, 0xF7, 0x9E, 0x5E]) // latitude
        #expect(Array(bytes[19...20]) == [0x07, 0xEA])            // year 2026
        #expect(bytes[21] == 0x07)                                // month
        #expect(bytes[22] == 0x0E)                                // day
        #expect(bytes[23] == 0x0C)                                // hour
        #expect(bytes[24] == 0x22)                                // minute
        #expect(bytes[25] == 0x38)                                // second
        #expect(Array(bytes[91...92]) == [0x01, 0xE0])            // UTC+8 = 480 min
        #expect(Array(bytes[93...94]) == [0x00, 0x00])            // no DST
    }

    @Test("Packet without timezone is 91 bytes")
    func packetWithoutTimeZone() {
        let packet = SonyLocationPacket(
            latitude: 0, longitude: 0, year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        let bytes = packet.encoded()
        #expect(bytes.count == 91)
        #expect(Array(bytes[0...1]) == [0x00, 0x59]) // length = 89
        #expect(bytes[5] == 0x00)                    // tz/dst omitted
    }
}
