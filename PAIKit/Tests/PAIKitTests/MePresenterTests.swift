import XCTest

@testable import PAIKit

final class MePresenterTests: XCTestCase {
    private let presenter = MePresenter()

    private func entry(_ id: String, _ at: String) -> SelfReport { SelfReport(id: id, at: at) }

    func testEntriesGroupByTheBerlinDayNotTheUtcDay() {
        // 23:30 UTC on the 23rd is 00:30 on the 24th in Berlin (CET, winter).
        let groups = presenter.groups(
            of: [
                entry("a", "2026-11-23T23:30:00+00:00"), entry("b", "2026-11-24T10:00:00+00:00"),
                entry("c", "2026-11-23T10:00:00+00:00"),
            ], todayKey: "2026-11-24")
        XCTAssertEqual(groups.map(\.key), ["2026-11-24", "2026-11-23"])
        XCTAssertEqual(groups[0].entries.map(\.id), ["b", "a"])
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday"])
    }

    func testSelfReportDecodesTheWireShapeIncludingAnUnknownFeel() throws {
        let json = #"""
            {"self_reports": [{"id": "1", "at": "2026-11-24T19:41:00.506812+00:00", "text": null, "feel": "ecstatic",
            "private": true, "redacted": true, "source": "ios", "context": {"activity": null}}], "next_before": null}
            """#
        let page = try JSONDecoder().decode(SelfReportPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.selfReports[0].feel, .unrecognized("ecstatic"))
        XCTAssertTrue(page.selfReports[0].isPrivate)
        XCTAssertNotNil(page.selfReports[0].date)
    }

    func testFixtureCorpusDecodesIntoTheModels() throws {
        let overview = try JSONDecoder().decode(MeOverview.self, from: PaiFixtures.meOverview(state: nil, end: nil))
        XCTAssertEqual(overview.days.count, 14)
        XCTAssertEqual(overview.days.last?.date, overview.today)
        let day = try JSONDecoder().decode(MeDay.self, from: PaiFixtures.meDay(date: overview.today, state: nil))
        XCTAssertFalse(day.entries.isEmpty)
        let none = try JSONDecoder().decode(MeOverview.self, from: PaiFixtures.meOverview(state: "noGarmin", end: nil))
        XCTAssertFalse(none.sources.garminConnected)
    }

    func testDictatedWordsShowWithoutTheMarkerAndGetAVoiceChip() {
        let dictated = SelfReport(id: "1", at: "x", text: "stt-rec: slept badly, head is full", source: .ios)
        let words = presenter.words(of: dictated)
        XCTAssertEqual(words.text, "slept badly, head is full")
        XCTAssertTrue(words.spoken)
        XCTAssertEqual(presenter.sourceChip(dictated)?.text, "spoken")

        let mixed = SelfReport(id: "2", at: "x", text: "typed first stt-rec: then spoken", source: .ios)
        XCTAssertEqual(presenter.words(of: mixed).text, "typed first then spoken")

        let typed = SelfReport(id: "3", at: "x", text: "just typed", source: .ios)
        XCTAssertFalse(presenter.words(of: typed).spoken)
        XCTAssertNil(presenter.sourceChip(typed))

        let onlyMarker = SelfReport(id: "4", at: "x", text: "stt-rec: ", source: .ios)
        XCTAssertNil(presenter.words(of: onlyMarker).text)
    }

    func testTodayDrawsOnlyWhatExistsAndTheNumbersAboutPaiComeLast() {
        let day = MeDay(date: "2026-11-24")
        let full = MeOverview(
            today: "2026-11-24", days: [day], lookingBack: SelfReport(id: "1", at: "x"),
            notes: [MeNote(key: "now", title: "Now", noteId: "n")], review: MeReview(title: "t", noteId: "n"))
        XCTAssertEqual(
            MeLayout.todaySections(for: full, ribbon: true, tasks: true, plan: true),
            [.ribbon, .body, .write, .review, .tasks, .plan, .diary, .lookingBack, .pai, .notes])
        let bare = MeOverview(today: "2026-11-24", days: [day])
        XCTAssertEqual(
            MeLayout.todaySections(for: bare, ribbon: false, tasks: false, plan: false), [.body, .write, .diary, .pai])
        XCTAssertEqual(
            MeLayout.gridRows(garminConnected: true),
            [
                .diary, .night, .asleep, .sleepScoreTrend, .sleepScore, .batteryTrend, .battery, .moved, .messages,
                .agents,
            ])
        XCTAssertEqual(MeLayout.gridRows(garminConnected: false), [.diary, .messages, .agents])
    }

    func testTheReviewNamesTheCompassSessionByIdAndAnOldPromptFieldIsIgnored() throws {
        let json = #"""
            {"today": "2026-11-24", "days": [], "review": {"title": "Week 47", "note_id": "n1", "week": 47,
             "compass_session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "compass_session_prompt": "old"}}
            """#
        let overview = try JSONDecoder().decode(MeOverview.self, from: Data(json.utf8))
        XCTAssertEqual(overview.review?.compassSessionId, "305df4d3-1554-4fc3-be04-39a354a9e619")
        let none = #"{"today": "d", "days": [], "review": {"title": "t", "note_id": "n", "compass_session_id": null}}"#
        XCTAssertNil(try JSONDecoder().decode(MeOverview.self, from: Data(none.utf8)).review?.compassSessionId)
    }

    func testCalendarEventsDecodeOptionallyAndTheRowFollowsTheSource() throws {
        // An older server sends no events, no kind and no calendar source: nothing breaks.
        let old = try JSONDecoder().decode(MeDay.self, from: Data(#"{"date": "2026-11-24"}"#.utf8))
        XCTAssertEqual(old.events, [])
        let day = try JSONDecoder().decode(
            MeDay.self,
            from: Data(
                #"""
                {"date": "2026-11-24", "events": [
                 {"title": "Dentist", "start_at": "2026-11-24T08:30:00+00:00", "end_at": "2026-11-24T09:15:00+00:00",
                  "all_day": false, "calendar": "Personal"},
                 {"title": "Holiday", "start_at": "2026-11-23T23:00:00+00:00", "end_at": "2026-11-25T23:00:00+00:00",
                  "all_day": true, "calendar": "Holidays", "kind": "ambient"},
                 {"title": "Odd", "kind": "something-new"}]}
                """#.utf8))
        XCTAssertEqual(day.events.map(\.isPlan), [true, false, false])
        XCTAssertEqual(day.events.map(presenter.eventDetailLine), ["Dentist 09:30–10:15", "Holiday · all day", "Odd"])

        XCTAssertTrue(MeSources(calendar: MeSource(status: .ok)).calendarConnected)
        XCTAssertFalse(MeSources(calendar: MeSource(status: .notConfigured)).calendarConnected)
        XCTAssertFalse(MeSources().calendarConnected)
    }
}
