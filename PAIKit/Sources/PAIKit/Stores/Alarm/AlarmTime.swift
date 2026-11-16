import Foundation

/// How a picked hour and minute becomes the `fire_at` the server stores, and how an alarm reads.
public enum AlarmTime {

    /// The next moment the wall clock shows `hour:minute` — today when still ahead, otherwise
    /// tomorrow — in `calendar`'s time zone. The server never interprets local time, so this is
    /// the one place the day is decided.
    public static func nextOccurrence(
        hour: Int, minute: Int, after now: Date, calendar: Calendar = .current
    ) -> Date? {
        calendar.nextDate(
            after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime)
    }

    /// ISO-8601 UTC with an explicit `+00:00` offset, the form the backend itself writes.
    public static func wireString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let text = formatter.string(from: date)
        return text.hasSuffix("Z") ? String(text.dropLast()) + "+00:00" : text
    }

    /// `⏰ <name>`, how every client lists an alarm.
    public static func title(_ name: String) -> String { "⏰ \(name)" }
}
