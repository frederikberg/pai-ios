import Foundation

/// The hours the sessions are put away, as wall-clock times in the phone's own time zone. Crossing
/// midnight is the ordinary case (22:00 to 05:00); the start and the end are never the same time.
///
/// Whether a moment is inside is decided by the wall clock alone, so a night with a clock change
/// is still "22:00 to 05:00" on the dial. The server holds the same window with the zone's name
/// and applies the same rule, which is why a phone that is switched off at 22:00 still gets no push.
public struct SleepWindow: Codable, Equatable, Sendable {
    /// Minutes after midnight, `0..<1440`.
    public let startMinute: Int
    public let endMinute: Int

    public static let minutesPerDay = 24 * 60

    /// What a first enabling starts from.
    public static let standard = SleepWindow(startMinute: 22 * 60, endMinute: 5 * 60)!

    /// `nil` for a start equal to the end, or a time outside the day.
    public init?(startMinute: Int, endMinute: Int) {
        guard (0..<Self.minutesPerDay).contains(startMinute), (0..<Self.minutesPerDay).contains(endMinute),
            startMinute != endMinute
        else { return nil }
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    enum CodingKeys: String, CodingKey {
        case startMinute, endMinute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Int.self, forKey: .startMinute)
        let end = try container.decode(Int.self, forKey: .endMinute)
        guard let window = SleepWindow(startMinute: start, endMinute: end) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startMinute, in: container, debugDescription: "Not a sleep window")
        }
        self = window
    }

    /// `22:00` and `05:00`, as the server's `sleep.start` and `sleep.end`.
    public var startText: String { Self.text(startMinute) }
    public var endText: String { Self.text(endMinute) }
    public var label: String { "\(startText)–\(endText)" }

    static func text(_ minute: Int) -> String {
        let hour = minute / 60
        let rest = minute % 60
        return (hour < 10 ? "0" : "") + "\(hour):" + (rest < 10 ? "0" : "") + "\(rest)"
    }

    /// Whether `date` is inside the window, by the wall clock of `zone`.
    public func contains(_ date: Date, in zone: TimeZone) -> Bool {
        let minute = Self.minuteOfDay(date, in: zone)
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// The moment the window that holds `date` ends, `nil` when `date` is outside it.
    public func end(ofWindowContaining date: Date, in zone: TimeZone) -> Date? {
        guard contains(date, in: zone) else { return nil }
        return Self.next(minute: endMinute, after: date, in: zone)
    }

    /// The first moment after `date` at which the window starts or ends.
    public func nextBoundary(after date: Date, in zone: TimeZone) -> Date? {
        let start = Self.next(minute: startMinute, after: date, in: zone)
        let end = Self.next(minute: endMinute, after: date, in: zone)
        switch (start, end) {
        case let (start?, end?): return min(start, end)
        case let (start?, nil): return start
        case let (nil, end?): return end
        case (nil, nil): return nil
        }
    }

    private static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func minuteOfDay(_ date: Date, in zone: TimeZone) -> Int {
        let parts = calendar(in: zone).dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The next time the wall clock reads `minute`, strictly after `date`. A time the clock skips
    /// (the spring change) is the first time after the gap.
    private static func next(minute: Int, after date: Date, in zone: TimeZone) -> Date? {
        calendar(in: zone).nextDate(
            after: date, matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
            matchingPolicy: .nextTime)
    }
}
