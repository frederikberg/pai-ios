import XCTest

@testable import PAIKit

final class ClockTimeTests: XCTestCase {

    /// A 12-hour region, where a locale-following formatter would print "5:30 PM".
    private var usCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    func testAfternoonReadsOnA24HourClockUnderAnEnglishUSLocale() {
        let date = IsoTimestamp.date(from: "2026-11-16T16:30:00+00:00")!
        XCTAssertEqual(ClockTime.string(date, calendar: usCalendar), "17:30")
    }

    func testMorningKeepsItsLeadingZero() {
        let date = IsoTimestamp.date(from: "2026-11-16T05:10:00+00:00")!
        XCTAssertEqual(ClockTime.string(date, calendar: usCalendar), "06:10")
    }

    func testMidnightIsZeroHundred() {
        let date = IsoTimestamp.date(from: "2026-11-15T23:05:00+00:00")!
        XCTAssertEqual(ClockTime.string(date, calendar: usCalendar), "00:05")
    }

    func testWeatherTimesUseTheSameClock() {
        let now = IsoTimestamp.date(from: "2026-11-16T14:00:00+00:00")!
        let presenter = WeatherPresenter(now: now, calendar: usCalendar)
        let later = WeatherLater(
            chance: 60, verdict: .rain, at: "2026-11-16T16:50:00+00:00")
        XCTAssertEqual(presenter.laterRow(later).detail, "from ~17:50")
    }

    func testPickerLocaleUsesA24HourClock() {
        let template =
            DateFormatter.dateFormat(
                fromTemplate: "j", options: 0, locale: ClockTime.pickerLocale) ?? ""
        XCTAssertFalse(template.contains("a"), template)
    }
}
