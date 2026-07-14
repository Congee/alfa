import Foundation
import Testing
@testable import SonyProtocol

/// Tests for the `CC13` clock-sync packet encoder. These pin the **byte layout** for known inputs; they deliberately
/// do not assert on-camera behavior (the packet is 🟡/unverified on the A7R V — see `SonyTimePacket`).
@Suite("CC13 time packet")
struct TimePacketTests {
    private func date(_ tz: TimeZone, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    @Test("Encodes the documented 13-byte layout (positive whole-hour offset)")
    func encodesPositiveOffset() {
        let packet = SonyTimePacket(
            year: 2026, month: 7, day: 14, hour: 15, minute: 30, second: 45,
            isDaylightSaving: false, offsetHours: 8, offsetMinutes: 0
        )
        // 2026 = 0x07EA.
        #expect(packet.encoded() == [0x0C, 0x00, 0x00, 0x07, 0xEA, 7, 14, 15, 30, 45, 0x00, 8, 0])
    }

    @Test("Negative offset encodes as a signed byte; minutes are the magnitude")
    func encodesNegativeOffsetWithMinutes() {
        let packet = SonyTimePacket(
            year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5,
            isDaylightSaving: false, offsetHours: -3, offsetMinutes: 30
        )
        let bytes = packet.encoded()
        #expect(bytes[11] == UInt8(bitPattern: -3)) // 0xFD
        #expect(bytes[12] == 30)
    }

    @Test("DST flag is set when daylight saving is in effect")
    func encodesDaylightSavingFlag() {
        let packet = SonyTimePacket(
            year: 2026, month: 7, day: 1, hour: 12, minute: 0, second: 0,
            isDaylightSaving: true, offsetHours: -5, offsetMinutes: 0
        )
        #expect(packet.encoded()[10] == 0x01)
    }

    @Test("Derives local wall-clock fields and base offset from a fixed-offset zone (UTC+8)")
    func derivesFromUTCPlus8() {
        let tz = TimeZone(secondsFromGMT: 8 * 3600)!
        let packet = SonyTimePacket(date: date(tz, 2026, 7, 14, 15, 30, 45), timeZone: tz)
        #expect(packet.year == 2026)
        #expect(packet.month == 7)
        #expect(packet.day == 14)
        #expect(packet.hour == 15)
        #expect(packet.minute == 30)
        #expect(packet.second == 45)
        #expect(packet.offsetHours == 8)
        #expect(packet.offsetMinutes == 0)
        #expect(packet.isDaylightSaving == false)
    }

    @Test("Half-hour positive offset (UTC+5:30) splits into hour + magnitude minute")
    func derivesHalfHourOffset() {
        let tz = TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60)!
        let packet = SonyTimePacket(date: date(tz, 2026, 3, 1, 9, 0, 0), timeZone: tz)
        #expect(packet.offsetHours == 5)
        #expect(packet.offsetMinutes == 30)
    }

    @Test("Negative half-hour offset (UTC−3:30) keeps sign on hour, magnitude on minute")
    func derivesNegativeHalfHourOffset() {
        let tz = TimeZone(secondsFromGMT: -(3 * 3600 + 30 * 60))!
        let packet = SonyTimePacket(date: date(tz, 2026, 3, 1, 9, 0, 0), timeZone: tz)
        #expect(packet.offsetHours == -3)
        #expect(packet.offsetMinutes == 30)
    }
}
