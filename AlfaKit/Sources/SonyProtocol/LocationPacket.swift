import Foundation

/// The Sony BLE location + date/time packet written to characteristic `DD11`.
///
/// Layout is big-endian and documented byte-for-byte in `docs/03-ble-protocol.md`. The packet is 95 bytes when a
/// timezone/DST block is included, 91 bytes otherwise. All timestamp fields are **UTC**.
public struct SonyLocationPacket: Sendable, Equatable {
    /// Optional timezone/DST block. When `nil`, the shorter 91-byte packet is produced.
    public struct TimeZoneBlock: Sendable, Equatable {
        /// Total UTC→local offset in minutes (e.g. UTC+8 → `480`), excluding the DST component.
        public var offsetMinutes: Int16
        /// Daylight-saving offset in minutes (`0` when not in effect).
        public var dstMinutes: Int16

        public init(offsetMinutes: Int16, dstMinutes: Int16) {
            self.offsetMinutes = offsetMinutes
            self.dstMinutes = dstMinutes
        }
    }

    public var latitude: Double
    public var longitude: Double
    public var year: UInt16
    public var month: UInt8
    public var day: UInt8
    public var hour: UInt8
    public var minute: UInt8
    public var second: UInt8
    public var timeZone: TimeZoneBlock?

    /// Memberwise initializer over explicit UTC fields — the deterministic path used by tests.
    public init(
        latitude: Double,
        longitude: Double,
        year: UInt16,
        month: UInt8,
        day: UInt8,
        hour: UInt8,
        minute: UInt8,
        second: UInt8,
        timeZone: TimeZoneBlock? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.timeZone = timeZone
    }

    /// Degrees are encoded as `int32` after scaling by 10^7.
    public static let coordinateScale = 10_000_000.0

    /// Encodes the packet to the exact byte sequence written to `DD11`.
    public func encoded() -> [UInt8] {
        let includeTimeZone = timeZone != nil
        var body: [UInt8] = []
        body.reserveCapacity(93)

        body += [0x08, 0x02, 0xFC]                 // offsets 2–4: fixed
        body.append(includeTimeZone ? 0x03 : 0x00) // offset 5: tz/dst-present flag
        body += [0x00, 0x00, 0x10, 0x10, 0x10]     // offsets 6–10: fixed

        body += Self.int32BE(Self.scaledDegrees(latitude))  // offsets 11–14
        body += Self.int32BE(Self.scaledDegrees(longitude)) // offsets 15–18

        body += Self.uint16BE(year)                // offsets 19–20
        body += [month, day, hour, minute, second] // offsets 21–25

        body += [UInt8](repeating: 0x00, count: 65) // offsets 26–90: padding

        if let timeZone {
            body += Self.int16BE(timeZone.offsetMinutes) // offsets 91–92
            body += Self.int16BE(timeZone.dstMinutes)    // offsets 93–94
        }

        // Prepend the 2-byte length of everything after it.
        return Self.uint16BE(UInt16(body.count)) + body
    }

    // MARK: - Encoding helpers

    static func scaledDegrees(_ degrees: Double) -> Int32 {
        Int32((degrees * coordinateScale).rounded())
    }

    static func uint16BE(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    static func int16BE(_ value: Int16) -> [UInt8] {
        uint16BE(UInt16(bitPattern: value))
    }

    static func int32BE(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [
            UInt8((bits >> 24) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8(bits & 0xFF),
        ]
    }
}

public extension SonyLocationPacket {
    /// Convenience initializer from a `Date` and `TimeZone`.
    ///
    /// UTC calendar fields are derived with a UTC-fixed Gregorian calendar. When `timeZone` is provided, the
    /// packet's tz/dst block is populated from its offset at `date`.
    init(latitude: Double, longitude: Double, date: Date, timeZone: TimeZone? = nil) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let block: TimeZoneBlock? = timeZone.map { tz in
            let dst = Int(tz.daylightSavingTimeOffset(for: date) / 60)
            let total = tz.secondsFromGMT(for: date) / 60
            return TimeZoneBlock(offsetMinutes: Int16(total - dst), dstMinutes: Int16(dst))
        }

        self.init(
            latitude: latitude,
            longitude: longitude,
            year: UInt16(c.year ?? 0),
            month: UInt8(c.month ?? 0),
            day: UInt8(c.day ?? 0),
            hour: UInt8(c.hour ?? 0),
            minute: UInt8(c.minute ?? 0),
            second: UInt8(c.second ?? 0),
            timeZone: block
        )
    }
}
