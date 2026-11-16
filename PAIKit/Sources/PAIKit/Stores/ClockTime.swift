import Foundation

/// Wall-clock times are always shown on a 24-hour clock, whatever the phone's region or its
/// 12-hour setting say. Every alarm and weather time goes through here.
public enum ClockTime {

    /// "17:30": `date` as the wall clock reads in `calendar`'s time zone.
    public static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// A locale whose system pickers run on a 24-hour clock; `DatePicker` has no clock-style
    /// setting of its own, it follows the environment's locale.
    public static let pickerLocale = Locale(identifier: "en_GB")
}
