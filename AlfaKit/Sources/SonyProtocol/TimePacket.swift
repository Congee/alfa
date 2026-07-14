import Foundation

/// The Sony BLE clock-sync packet written to characteristic `CC13` on the bodies that expose it.
///
/// **Verified on the A7R V (fw 4.0)** — `docs/08` IT-4: with a deliberately-wrong camera clock and "Time Correction"
/// on, the clock lands correct, confirming the time-base interpretation here (**local wall-clock** date/time fields
/// plus an explicit base UTC offset and a DST flag). The 13-byte layout is documented in `docs/03-ble-protocol.md`.
/// The BLE layer treats a missing `CC13` characteristic as a clean no-op, so bodies that don't expose it are
/// unaffected.
///
/// Layout (13 bytes, big-endian year):
/// `[0x0C, 0x00, 0x00, yearHi, yearLo, month, day, hour, minute, second, dstFlag, signedOffsetHour, offsetMinute]`.
public struct SonyTimePacket: Sendable, Equatable {
    public var year: UInt16
    public var month: UInt8
    public var day: UInt8
    public var hour: UInt8
    public var minute: UInt8
    public var second: UInt8
    /// Whether daylight saving is in effect at `date` (the `dstFlag` byte).
    public var isDaylightSaving: Bool
    /// Whole-hour part of the **base** UTC offset (excluding DST), signed — e.g. UTC−3 → `-3`.
    public var offsetHours: Int8
    /// Minute part of the base UTC offset, magnitude only — e.g. UTC+5:30 → `30`.
    public var offsetMinutes: UInt8

    /// Memberwise initializer over explicit fields — the deterministic path used by tests.
    public init(
        year: UInt16,
        month: UInt8,
        day: UInt8,
        hour: UInt8,
        minute: UInt8,
        second: UInt8,
        isDaylightSaving: Bool,
        offsetHours: Int8,
        offsetMinutes: UInt8
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.isDaylightSaving = isDaylightSaving
        self.offsetHours = offsetHours
        self.offsetMinutes = offsetMinutes
    }

    /// Derives the packet from a `Date` and `TimeZone`. Date/time fields are the **local** wall-clock reading in
    /// `timeZone`; the offset fields carry the base (non-DST) UTC offset, with the DST component reported separately.
    public init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let dstSeconds = Int(timeZone.daylightSavingTimeOffset(for: date))
        let baseMinutes = (timeZone.secondsFromGMT(for: date) - dstSeconds) / 60

        self.init(
            year: UInt16(c.year ?? 0),
            month: UInt8(c.month ?? 0),
            day: UInt8(c.day ?? 0),
            hour: UInt8(c.hour ?? 0),
            minute: UInt8(c.minute ?? 0),
            second: UInt8(c.second ?? 0),
            isDaylightSaving: dstSeconds != 0,
            offsetHours: Int8(baseMinutes / 60),
            offsetMinutes: UInt8(abs(baseMinutes % 60))
        )
    }

    /// Encodes the packet to the exact byte sequence written to `CC13`.
    public func encoded() -> [UInt8] {
        [
            0x0C, 0x00, 0x00,
            UInt8(year >> 8), UInt8(year & 0xFF),
            month, day, hour, minute, second,
            isDaylightSaving ? 0x01 : 0x00,
            UInt8(bitPattern: offsetHours),
            offsetMinutes,
        ]
    }
}
