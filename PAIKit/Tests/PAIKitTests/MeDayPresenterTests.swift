import XCTest

@testable import PAIKit

/// The day-shaped rules of the Me screens: what lies on a day's axis, which rows a card holds,
/// where a night bar sits. Winter dates, so Berlin is UTC+1 and a wire time is written an hour
/// behind the clock the screen shows.
final class MeDayPresenterTests: XCTestCase {
    private let presenter = MePresenter()
    private let day = "2026-11-24"

    private func event(
        _ title: String, _ start: String, _ end: String, allDay: Bool = false, kind: MeEvent.Kind = .plan
    )
        -> MeEvent
    {
        MeEvent(title: title, startAt: start, endAt: end, allDay: allDay, kind: kind)
    }

    private func date(_ wire: String) -> Date { IsoTimestamp.date(from: wire) ?? Date.distantPast }

    // MARK: Ribbon

    func testASleepThatBeganTheEveningBeforeIsCutAtMidnightAndDrawnToWaking() {
        let body = MeBody(wakeAt: "2026-11-24T06:42:00+00:00", bedAt: "2026-11-23T21:30:00+00:00")
        let ribbon = presenter.ribbon(day: MeDay(date: day, body: body), tasks: nil, now: nil)
        XCTAssertEqual(ribbon.sleep, MeSpan(start: 0, end: 7 * 60 + 42))
        let after = MeBody(wakeAt: "2026-11-24T06:42:00+00:00", bedAt: "2026-11-23T23:35:00+00:00")
        let late = presenter.ribbon(day: MeDay(date: day, body: after), tasks: nil, now: nil)
        XCTAssertEqual(late.sleep, MeSpan(start: 35, end: 7 * 60 + 42))
    }

    func testWithoutABedTimeTheHoursAsleepAreCountedBackFromWaking() {
        let body = MeBody(sleepSeconds: 6 * 3600, wakeAt: "2026-11-24T06:42:00+00:00")
        let ribbon = presenter.ribbon(day: MeDay(date: day, body: body), tasks: nil, now: nil)
        XCTAssertEqual(ribbon.sleep, MeSpan(start: 102, end: 462))
        XCTAssertNil(presenter.ribbon(day: MeDay(date: day), tasks: nil, now: nil).sleep)
    }

    func testAnEventEndingAtMidnightBelongsToTheDayBeforeAndAllDayOnesAreNotLanes() {
        let events = [
            event("Late", "2026-11-23T22:00:00+00:00", "2026-11-23T23:00:00+00:00"),
            event("Today", "2026-11-24T13:00:00+00:00", "2026-11-24T14:00:00+00:00"),
            event("Holiday", "2026-11-23T23:00:00+00:00", "2026-11-24T23:00:00+00:00", allDay: true),
            event("Birthday", "2026-11-24T09:00:00+00:00", "2026-11-24T10:00:00+00:00", kind: .ambient),
        ]
        let today = presenter.ribbon(day: MeDay(date: day, events: events), tasks: nil, now: nil)
        XCTAssertEqual(today.plans, [MeSpan(start: 14 * 60, end: 15 * 60)])
        let before = presenter.ribbon(day: MeDay(date: "2026-11-23", events: events), tasks: nil, now: nil)
        XCTAssertEqual(before.plans.count, 1)
        XCTAssertEqual(before.plans.first?.end, 1440)
    }

    func testNeighbouringSlotsMergeAndOnlyTodayGetsANowLine() {
        XCTAssertEqual(
            presenter.slotSpans([5, 4, 6, 20, 287, 300, -1]),
            [MeSpan(start: 20, end: 35), MeSpan(start: 100, end: 105), MeSpan(start: 1435, end: 1440)])
        let moment = date("2026-11-24T10:33:00+00:00")
        let today = presenter.ribbon(day: MeDay(date: day), tasks: nil, now: moment)
        XCTAssertEqual(today.now, 11 * 60 + 33)
        XCTAssertNil(presenter.ribbon(day: MeDay(date: "2026-11-23"), tasks: nil, now: moment).now)
    }

    func testTickedTasksSitOnTheirOwnBerlinDayAtTheirTime() {
        let tasks = MeTasks(
            date: day,
            done: [
                MeTaskDone(id: "a", title: "A", completedAt: "2026-11-24T08:42:00+00:00"),
                MeTaskDone(id: "b", title: "B", completedAt: "2026-11-23T23:30:00+00:00"),
                // 00:30 on the 25th: another day's tick.
                MeTaskDone(id: "c", title: "C", completedAt: "2026-11-24T23:30:00+00:00"),
                MeTaskDone(
                    kind: .group, id: "grocery", title: "grocery", completedAt: "2026-11-24T15:25:00+00:00",
                    fromAt: "2026-11-24T15:02:00+00:00", count: 9),
            ])
        let ribbon = presenter.ribbon(day: MeDay(date: day), tasks: tasks, now: nil)
        // 23:30 UTC on the 23rd is 00:30 on the 24th in Berlin.
        XCTAssertEqual(
            ribbon.done,
            [MeSpan(start: 30, end: 30), MeSpan(start: 582, end: 582), MeSpan(start: 962, end: 985)])
        XCTAssertTrue(ribbon.hasData)
        XCTAssertFalse(presenter.ribbon(day: MeDay(date: day), tasks: nil, now: nil).hasData)
    }

    func testTheNarrowRibbonDropsTheHourThatWouldTouchTheTenPmMark() {
        XCTAssertEqual(MePresenter.ribbonHours(width: 333), [6, 9, 12, 15, 18])
        XCTAssertEqual(MePresenter.ribbonHours(width: 600), [6, 9, 12, 15, 18, 21])
    }

    // MARK: Lines

    func testTheBodyLineLeavesOutWhatIsMissing() {
        let full = MeBody(
            sleepSeconds: 23820, sleepScore: 47, wakeAt: "2026-11-24T06:42:00+00:00",
            bedAt: "2026-11-23T23:35:00+00:00", bodyBatteryWake: 54)
        let lines = presenter.bodyLines(day: MeDay(date: day, body: full))
        XCTAssertEqual(lines.sleep.map(\.text).joined(), "6 h 37 asleep · 00:35 → 07:42 · score 47")
        XCTAssertEqual(lines.sleep.filter(\.strong).map(\.text), ["6 h 37", "47"])
        XCTAssertEqual(lines.battery.map(\.text).joined(), "54 body battery on waking")

        let noBed = MeBody(sleepSeconds: 23820, wakeAt: "2026-11-24T06:42:00+00:00")
        XCTAssertEqual(
            presenter.bodyLines(day: MeDay(date: day, body: noBed)).sleep.map(\.text).joined(),
            "6 h 37 asleep · woke 07:42")
        XCTAssertTrue(presenter.bodyLines(day: MeDay(date: day)).isEmpty)
    }

    func testTheNightFactNamesTheWindowAndTheTasksLineNamesFirstAndLast() {
        let body = MeBody(
            sleepSeconds: 10260, sleepScore: 37, wakeAt: "2026-11-24T01:02:00+00:00",
            bedAt: "2026-11-23T22:05:00+00:00",
            bodyBatteryWake: 47)
        XCTAssertEqual(
            presenter.nightFact(body), "Night 23:05 → 02:02 · 2 h 51 asleep · score 37 · battery on waking 47")
        let tasks = MeTasks(
            date: day,
            done: [
                MeTaskDone(id: "a", title: "A", completedAt: "2026-11-24T17:40:00+00:00"),
                MeTaskDone(id: "b", title: "B", completedAt: "2026-11-24T09:05:00+00:00"),
            ])
        XCTAssertEqual(presenter.tasksDoneLine(tasks), "2 tasks done · first 10:05, last 18:40")
        XCTAssertNil(presenter.tasksDoneLine(MeTasks(date: day)))
    }

    func testAgentsAreOnlyAnOvernightRunFromFortyFiveMinutes() {
        XCTAssertNil(presenter.overnightLabel(minutes: 44))
        XCTAssertEqual(presenter.overnightLabel(minutes: 45), "1h")
        XCTAssertEqual(presenter.overnightLabel(minutes: 380), "6h")
        XCTAssertNil(presenter.overnightLabel(minutes: nil))
    }

    // MARK: Cards

    func testTheTodayCardHoldsFixedOpenAndDoneAndSaysWhenTheReadFailed() throws {
        let tasks = MeTasks(
            date: day, status: .unavailable, asOf: "2026-11-24T13:02:00+00:00",
            open: [
                MeTaskOpen(id: "1", title: "Laundry"),
                MeTaskOpen(id: "2", title: "Book", dueTime: "17:00", deadline: "2026-11-26", overdueDays: 2),
            ],
            done: [
                MeTaskDone(
                    kind: .group, id: "grocery", title: "grocery", completedAt: "2026-11-24T15:25:00+00:00",
                    fromAt: "2026-11-24T15:02:00+00:00", count: 9),
                MeTaskDone(id: "d", title: "Pharmacy", completedAt: "2026-11-24T08:42:00+00:00"),
            ])
        let events = [
            event("Earlier", "2026-11-24T08:00:00+00:00", "2026-11-24T09:00:00+00:00"),
            event("Status call", "2026-11-24T13:00:00+00:00", "2026-11-24T14:00:00+00:00"),
            event("Away", "2026-11-23T23:00:00+00:00", "2026-11-24T23:00:00+00:00", allDay: true),
        ]
        let now = date("2026-11-24T10:33:00+00:00")
        let card = try XCTUnwrap(presenter.todayCard(tasks: tasks, events: events, now: now, todayKey: day))
        XCTAssertEqual(card.fixed.map(\.title), ["Away", "Status call"])
        XCTAssertEqual(card.fixed.last?.suffix, "until 15:00")
        XCTAssertEqual(card.open.map(\.suffix), [nil, "17:00 · latest Thu · overdue 2 d"])
        XCTAssertEqual(card.done.map(\.title), ["🛒 9 grocery items", "Pharmacy"])
        XCTAssertEqual(card.done.map(\.time), ["16:02–16:25", "09:42"])
        XCTAssertEqual(card.countLine, "10 done · 2 to come · 2 fixed")
        XCTAssertEqual(card.footer, "Todos unreachable · showing 14:02")

        let off = MeTasks(date: day, status: .notConfigured)
        XCTAssertNil(presenter.todayCard(tasks: off, events: events, now: now, todayKey: day))
        XCTAssertNil(presenter.todayCard(tasks: nil, events: events, now: now, todayKey: day))
    }

    /// The Desk comes first, cut into its sections in the order the answer gives, and the rows
    /// off it follow under their own caption; a row from a server that names no Desk is off it.
    func testTheTodayCardGroupsTheDeskByItsSectionsAheadOfTheRest() throws {
        let tasks = try JSONDecoder().decode(
            MeTasks.self,
            from: Data(
                #"""
                {"date": "2026-11-24", "status": "ok", "source": "todos", "as_of": null, "done": [], "moved": 0,
                 "open": [{"id": "a", "title": "A", "desk": true, "section": null},
                          {"id": "b", "title": "B", "desk": true, "section": "Morning"},
                          {"id": "c", "title": "C", "desk": true, "section": "Morning"},
                          {"id": "d", "title": "D", "desk": true, "section": "Later"},
                          {"id": "e", "title": "E", "desk": false, "section": null},
                          {"id": "f", "title": "F"}]}
                """#.utf8))
        let now = date("2026-11-24T10:33:00+00:00")
        let card = try XCTUnwrap(presenter.todayCard(tasks: tasks, events: [], now: now, todayKey: day))
        XCTAssertEqual(card.desk.map(\.title), [nil, "Morning", "Later"])
        XCTAssertEqual(card.desk.map { $0.rows.map(\.title) }, [["A"], ["B", "C"], ["D"]])
        XCTAssertEqual(card.open.map(\.title), ["E", "F"])
        XCTAssertEqual(card.openCaption, "Due")
        XCTAssertEqual(card.countLine, "6 to come")
    }

    /// A day without a value has no point and breaks the line; a higher value sits higher.
    func testATrendHasAPointPerDayWithAValueAndNeverBridgesADayWithout() {
        let trend = presenter.trend([50, nil, 70, 90, nil, 60])
        XCTAssertEqual(trend.points.map(\.index), [0, 2, 3, 5])
        XCTAssertEqual(trend.runs.map { $0.map(\.index) }, [[2, 3]])
        let y = Dictionary(uniqueKeysWithValues: trend.points.map { ($0.index, $0.y) })
        XCTAssertLessThan(y[3] ?? 0, y[2] ?? 0)
        XCTAssertLessThan(y[2] ?? 0, y[0] ?? 0)
        XCTAssertTrue(trend.points.allSatisfy { $0.y >= 0 && $0.y <= MePresenter.trendRowHeight })
        XCTAssertEqual(presenter.trend([nil, nil]), MeTrend(points: [], runs: []))
        XCTAssertEqual(presenter.sleepClock(seconds: 22_500), "6:15")
    }

    func testThePlanCardNeedsWordsAndNamesWhenItWasAgreed() throws {
        let counts = MePlan(appetite: "big", planned: 3, done: 2, added: 1)
        XCTAssertNil(presenter.planCard(counts, todayKey: day))
        XCTAssertNil(presenter.planCard(MePlan(text: "  \n"), todayKey: day))
        let plan = MePlan(
            appetite: "big", planned: 3, done: 2, added: 1, text: "Big day.", updatedAt: "2026-11-24T07:14:00+00:00")
        let card = try XCTUnwrap(presenter.planCard(plan, todayKey: day))
        XCTAssertEqual(card.agreed, "as agreed this morning · 08:14")
        XCTAssertEqual(card.progress, "2 of 3 done, 1 added later")
        let later = MePlan(text: "Big day.", updatedAt: "2026-11-24T13:02:00+00:00")
        XCTAssertEqual(presenter.planCard(later, todayKey: day)?.agreed, "as agreed · 14:02")
    }

    func testTheSourcesLineNamesOnlySourcesThatAnsweredWell() {
        let now = date("2026-11-24T10:33:00+00:00")
        let sources = MeSources(garmin: MeSource(status: .ok, asOf: "2026-11-24T09:31:00+00:00"))
        let overview = MeOverview(today: day, sources: sources, days: [])
        let ok = MeTasks(date: day, asOf: "2026-11-24T10:31:00+00:00")
        XCTAssertEqual(
            presenter.sourcesLine(overview: overview, tasks: ok, todayFinal: false, now: now),
            "Garmin 10:31 · Todos 2 min ago · today not final")
        let down = MeTasks(date: day, status: .unavailable, asOf: "2026-11-24T10:31:00+00:00")
        let failed = MeOverview(
            today: day, sources: MeSources(garmin: MeSource(status: .unavailable)), days: [])
        XCTAssertNil(presenter.sourcesLine(overview: failed, tasks: down, todayFinal: false, now: now))
    }

    // MARK: Grid

    func testTheNightBarSitsBetweenBedAndWakeOnTheTwentyOneToElevenAxis() throws {
        let bar = try XCTUnwrap(
            presenter.nightBar(MeBody(wakeAt: "2026-11-24T06:42:00+00:00", bedAt: "2026-11-23T23:35:00+00:00")))
        // 00:35 is 3.58 h past 21:00, 07:42 is 10.7 h.
        XCTAssertEqual(bar.top, 14.33, accuracy: 0.01)
        XCTAssertEqual(bar.height, 42.8 - 14.33, accuracy: 0.01)
        let early = try XCTUnwrap(
            presenter.nightBar(MeBody(wakeAt: "2026-11-24T06:42:00+00:00", bedAt: "2026-11-23T16:00:00+00:00")))
        XCTAssertEqual(early.top, 0)
        let lateWake = try XCTUnwrap(
            presenter.nightBar(MeBody(wakeAt: "2026-11-24T13:00:00+00:00", bedAt: "2026-11-23T23:35:00+00:00")))
        XCTAssertEqual(lateWake.top + lateWake.height, MePresenter.nightRowHeight, accuracy: 0.001)
        let hoursOnly = try XCTUnwrap(
            presenter.nightBar(MeBody(sleepSeconds: 6 * 3600, wakeAt: "2026-11-24T06:42:00+00:00")))
        XCTAssertEqual(hoursOnly.height, 24)
        XCTAssertEqual(hoursOnly.top + hoursOnly.height, 42.8, accuracy: 0.01)
        XCTAssertNil(presenter.nightBar(MeBody(sleepSeconds: 3600)))
    }

    /// The web puts an hour between 11:00 and 21:00 at the top for a bedtime and at the bottom for a
    /// waking time (`nightY` in `meModel.ts`); a bedtime at 11:30 is the top, not the bottom.
    func testAnHourInsideTheDaytimeGapClampsByItsRoleLikeTheWeb() throws {
        XCTAssertEqual(MePresenter.nightY(hour: 11.5, role: .bed), 0)
        XCTAssertEqual(MePresenter.nightY(hour: 11.5, role: .wake), MePresenter.nightRowHeight)
        XCTAssertEqual(MePresenter.nightY(hour: 21, role: .wake), 0)
        XCTAssertEqual(MePresenter.nightY(hour: 10.9, role: .bed), (10.9 + 3) * 4, accuracy: 0.001)
        // 11:30 in Berlin in November is 10:30 UTC.
        let bar = try XCTUnwrap(
            presenter.nightBar(MeBody(wakeAt: "2026-11-24T06:42:00+00:00", bedAt: "2026-11-24T10:30:00+00:00")))
        XCTAssertEqual(bar.top, 0)
    }

    func testTheDiaryRowDrawsOneDotPerEntryWithAFaceOrWithoutAndStopsAtSix() {
        let entries = [
            SelfReport(id: "1", at: "x", feel: .good), SelfReport(id: "2", at: "x"),
            SelfReport(id: "3", at: "x", isPrivate: true), SelfReport(id: "4", at: "x", feel: .heavy, isPrivate: true),
        ]
        XCTAssertEqual(presenter.diaryDots(entries), [.face(.good), .noFace, .privateNoFace, .face(.heavy)])
        let many = (0..<9).map { SelfReport(id: "\($0)", at: "x", feel: .okay) }
        XCTAssertEqual(presenter.diaryDots(many).count, 6)
    }

    func testMessageBarsScaleToTheBusiestDayButNeverVanish() {
        let days = [
            MeDay(date: "a", pai: MePai(messages: 100)), MeDay(date: "b", pai: MePai(messages: 1)), MeDay(date: "c"),
        ]
        let busiest = presenter.busiestDay(days)
        XCTAssertEqual(busiest, 100)
        XCTAssertEqual(presenter.messageBarHeight(messages: 100, busiest: busiest), 28)
        XCTAssertEqual(presenter.messageBarHeight(messages: 1, busiest: busiest), 2)
        XCTAssertEqual(presenter.messageBarHeight(messages: 5, busiest: 0), 2)
    }

    func testDiaryCountsAreByFaceAndLockOverTheDaysGiven() {
        let days = [
            MeDay(
                date: "a",
                entries: [
                    SelfReport(id: "1", at: "x", feel: .good), SelfReport(id: "2", at: "x", feel: .good),
                    SelfReport(id: "3", at: "x", isPrivate: true),
                ]),
            MeDay(date: "b", entries: [SelfReport(id: "4", at: "x", feel: .heavy, isPrivate: true)]),
        ]
        let counts = presenter.diaryCounts(days: days)
        XCTAssertEqual(counts, MeDiaryCounts(all: 4, good: 2, okay: 0, heavy: 1, locked: 2))
    }

    // MARK: Worked on

    func testWorkedOnGroupsPhasesByProjectAndHidesShortOnesBehindOneLine() {
        let held = [
            MeHeld(project: "Fleet", label: "Rollout", minutes: 100),
            MeHeld(project: "Fleet", label: "Review", minutes: 5),
            MeHeld(project: "Rules", label: "Tuning", minutes: 60),
            MeHeld(project: "Hikes", label: "Maps", minutes: 3),
            MeHeld(project: nil, label: nil, minutes: 2),
        ]
        let worked = presenter.workedOn(held)
        XCTAssertEqual(worked.shown.map(\.name), ["Fleet", "Rules"])
        XCTAssertEqual(worked.shown.first?.minutes, 105)
        XCTAssertEqual(worked.shown.first?.topics, 2)
        XCTAssertEqual(presenter.workedLine(worked.shown[0]), "2 topics · 1 h 45")
        XCTAssertEqual(worked.restLabel, "+ 2 more under 5 min")
        XCTAssertEqual(worked.rest.map(\.name), ["Hikes", MeHeld.untitled])

        let many = (0..<8).map { MeHeld(project: "P\($0)", label: "x", minutes: 30 + $0) }
        let capped = presenter.workedOn(many)
        XCTAssertEqual(capped.shown.count, 6)
        XCTAssertEqual(capped.restLabel, "+ 2 more")
    }

    func testTheDayRouteHeldPhasesKeepTheirSummariesWhenGrouped() {
        let held = [
            MeHeld(
                project: "Fleet",
                phases: [MeHeldPhase(name: "a", summary: "did a", minutes: 20), MeHeldPhase(name: "b", minutes: 10)])
        ]
        let project = presenter.workedOn(held).shown.first
        XCTAssertEqual(project?.minutes, 30)
        XCTAssertEqual(project?.phases.first?.summary, "did a")
    }

    // MARK: Wire

    func testADayWithoutTheNewFieldsDecodesAndFractionalNumbersDoNotFailIt() throws {
        let old = try JSONDecoder().decode(
            MeDay.self,
            from: Data(
                #"{"date": "2026-11-24", "body": {"sleep_seconds": 100}, "pai": {"messages": 3}, "plan": {"planned": 2}}"#
                    .utf8))
        XCTAssertNil(old.body?.bedAt)
        XCTAssertEqual(old.pai?.slots, [])
        XCTAssertNil(old.plan?.text)

        let now = try JSONDecoder().decode(
            MeDay.self,
            from: Data(
                #"{"date": "2026-11-24", "body": {"bed_at": "2026-11-23T23:35:00+00:00"}, "pai": {"messages": 3, "slots": [4, 5.0, 100.4]}, "plan": {"text": "x", "updated_at": "2026-11-24T07:14:00+00:00"}}"#
                    .utf8))
        XCTAssertEqual(now.body?.bedAt, "2026-11-23T23:35:00+00:00")
        XCTAssertEqual(now.pai?.slots, [4, 5, 100])
        XCTAssertEqual(now.plan?.updatedAt, "2026-11-24T07:14:00+00:00")
    }

    func testTasksDecodeWithFractionsUnknownKindsAndAMissingStatus() throws {
        let tasks = try JSONDecoder().decode(
            MeTasks.self,
            from: Data(
                #"""
                {"date": "2026-11-24", "as_of": null, "moved": 1.0,
                 "open": [{"id": "1", "title": "A", "position": 0.0, "labels": ["x"], "due_time": null,
                           "deadline": null, "overdue_days": 2.0}],
                 "done": [{"kind": "bundle", "id": "g", "title": "g", "completed_at": "2026-11-24T10:00:00+00:00",
                           "from_at": null, "count": 3.0}]}
                """#.utf8))
        XCTAssertEqual(tasks.status, .unavailable)
        XCTAssertEqual(tasks.open.first?.overdueDays, 2)
        XCTAssertEqual(tasks.done.first?.kind, .unrecognized("bundle"))
        XCTAssertEqual(tasks.moved, 1)
    }

    /// The card links where the answer says, and a row without an address is no link. An answer
    /// that names no address offers no link.
    func testTheTodayCardLinksWhereTheAnswerSays() throws {
        let now = date("2026-11-24T13:00:00+00:00")
        let todos = try JSONDecoder().decode(
            MeTasks.self,
            from: Data(
                #"""
                {"date": "2026-11-24", "status": "unavailable", "source": "todos",
                 "today_url": "https://pai.example.invalid/apps/todos", "as_of": "2026-11-24T10:31:00+00:00",
                 "open": [{"id": "a", "url": "https://pai.example.invalid/apps/todos/t/7", "title": "A"},
                          {"id": "b", "url": null, "title": "B"}],
                 "done": [], "moved": 0}
                """#.utf8))
        let card = try XCTUnwrap(presenter.todayCard(tasks: todos, events: [], now: now, todayKey: day))
        XCTAssertEqual(card.todayUrl?.absoluteString, "https://pai.example.invalid/apps/todos")
        XCTAssertEqual(card.open.map { $0.url?.absoluteString }, ["https://pai.example.invalid/apps/todos/t/7", nil])
        XCTAssertTrue(card.footer?.hasPrefix("Todos unreachable") == true)

        let older = try JSONDecoder().decode(
            MeTasks.self,
            from: Data(
                #"""
                {"date": "2026-11-24", "status": "ok", "as_of": null,
                 "open": [{"id": "a", "title": "A"}], "done": [], "moved": 0}
                """#.utf8))
        let olderCard = try XCTUnwrap(presenter.todayCard(tasks: older, events: [], now: now, todayKey: day))
        XCTAssertNil(olderCard.todayUrl)
        XCTAssertNil(olderCard.open.first?.url)
    }

    func testTheFixtureCorpusCarriesTheNewShapes() throws {
        let overview = try JSONDecoder().decode(MeOverview.self, from: PaiFixtures.meOverview(state: nil, end: nil))
        let today = try XCTUnwrap(overview.days.last)
        XCTAssertNotNil(today.body?.bedAt)
        XCTAssertFalse(today.pai?.slots.isEmpty ?? true)
        XCTAssertNotNil(presenter.planCard(today.plan, todayKey: overview.today))
        XCTAssertTrue(overview.days.contains { $0.events.contains { !$0.isPlan } })
        let tasks = try JSONDecoder().decode(MeTasks.self, from: PaiFixtures.meTasks(state: nil, date: nil))
        XCTAssertEqual(tasks.date, overview.today)
        XCTAssertEqual(tasks.status, .ok)
        XCTAssertFalse(tasks.open.isEmpty)
        let off = try JSONDecoder().decode(MeTasks.self, from: PaiFixtures.meTasks(state: "empty", date: nil))
        XCTAssertFalse(off.isConfigured)
    }
}
