import Foundation
import XCTest

@testable import PAIKit

/// The todo sheet, the day screens, search and arranging the desk, checked against what the web
/// app's own functions answer for the same inputs (`Resources/todos/web-sheet-vectors.json`).
@MainActor
final class TodosSheetTests: XCTestCase {

    private func vectors() throws -> [String: PaiJSONValue] {
        try TodosWireSamples.decode([String: PaiJSONValue].self, "web-sheet-vectors")
    }

    private func model<T: Decodable>(_ type: T.Type, _ value: PaiJSONValue?) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(try XCTUnwrap(value)))
    }

    private func object(_ value: PaiJSONValue?) -> [String: PaiJSONValue] {
        if case .object(let fields) = value { return fields }
        return [:]
    }

    private func array(_ value: PaiJSONValue?) -> [PaiJSONValue] {
        if case .array(let items) = value { return items }
        return []
    }

    private static let template: Todo = {
        let answer = try? TodosWireSamples.decode(TodosQueryAnswer.self, "query-open")
        return answer!.todos.first { $0.parentId == nil && $0.repeat == nil }!
    }()

    private func todos(_ statuses: [String: PaiJSONValue]) -> [String: Todo] {
        var out: [String: Todo] = [:]
        for (id, value) in statuses {
            var row = Self.template
            row.id = id
            if case .object(let fields) = value, case .string(let status) = fields["status"] {
                row.status = TodoStatus.knownValues[status] ?? .open
            }
            out[id] = row
        }
        return out
    }

    /// A row as the web's vector writes it.
    private func web(_ row: TodoDayRow) -> PaiJSONValue {
        switch row {
        case .heading(let key, let label, let sub, let date, let count):
            var fields: [String: PaiJSONValue] = [
                "kind": .string("header"), "key": .string(key), "label": .string(label),
                "count": .number(Decimal(count)),
            ]
            if let sub { fields["sub"] = .string(sub) }
            if let date { fields["date"] = .string(date) }
            return .object(fields)
        case .todo(let key, let id): return .object(["kind": .string("todo"), "key": .string(key), "id": .string(id)])
        case .ghost(let key, let todoId, let date):
            return .object([
                "kind": .string("ghost"), "key": .string(key), "todoId": .string(todoId), "date": .string(date),
            ])
        case .entry(let key, let todoId, let completionId, let at, let kind, let byLabel):
            return .object([
                "kind": .string("entry"), "key": .string(key), "todoId": .string(todoId),
                "completionId": .string(completionId), "at": .string(at), "entryKind": .string(kind),
                "byLabel": .string(byLabel),
            ])
        }
    }

    /// The web's rows carry fields the phone does not draw; compare what both have.
    private func comparable(_ value: PaiJSONValue) -> PaiJSONValue {
        var fields = object(value)
        for key in ["groupKey", "collapsed", "depth", "parentId", "expandable", "expanded"] { fields[key] = nil }
        return .object(fields)
    }

    func testUpcomingAndTheLogbookGroupByDayAsOnTheWeb() async throws {
        let vectors = try vectors()
        let upcoming = object(vectors["upcoming"])
        let answerFields = object(upcoming["input"]).merging(["todos": .object([:]), "seq": .number(1)]) { $1 }
        let answer = try model(TodosUpcomingAnswer.self, .object(answerFields))
        let pending = try model(
            [TodosQueuedChange].self,
            .array(
                array(upcoming["pending"]).map { change in
                    .object(object(change).merging(["source": .string("ios"), "queued_at": .string("x")]) { $1 })
                }))
        let rows = TodoDays.upcomingRows(
            answer, todos: todos(object(upcoming["todos"])), today: "2026-11-26", pending: pending)
        XCTAssertEqual(rows.map(web), array(upcoming["rows"]).map(comparable))

        let logbook = object(vectors["logbook"])
        let days = try model([TodosLogbookAnswer.Day].self, logbook["days"])
        let entries = TodoDays.logbookRows(days, todos: todos(object(logbook["todos"])), today: "2026-11-26")
        XCTAssertEqual(entries.map(web), array(logbook["rows"]).map(comparable))
    }

    /// The days behind come before the days ahead, with what was meant for them whether ticked
    /// or not; a deleted todo is not shown and a day left with nothing has no heading.
    func testUpcomingShowsTheDaysBehindWithTheirClosedTodos() async throws {
        let day = { (date: String, todos: [String]) in
            TodosUpcomingAnswer.Day(date: date, todos: todos, deadlines: [], ghosts: [])
        }
        let answer = TodosUpcomingAnswer(
            earlier: [day("2026-11-20", ["gone"]), day("2026-11-24", ["done", "open"])],
            days: [day("2026-11-27", ["next"])], later: [], someday: [], todos: [:], seq: 1)
        let known = todos([
            "gone": .object(["status": .string("deleted")]), "done": .object(["status": .string("done")]),
            "open": .object([:]), "next": .object([:]),
        ])
        let rows = TodoDays.upcomingRows(answer, todos: known, today: "2026-11-26", pending: [])
        XCTAssertEqual(
            rows.map(\.id),
            [
                TodoDays.dayKey("2026-11-24"), "day:2026-11-24/done", "day:2026-11-24/open",
                TodoDays.dayKey("2026-11-27"), "day:2026-11-27/next",
            ])
    }

    /// Looking further back asks for more days each time and stops asking once a look brings
    /// no older day.
    func testLookingFurtherBackInUpcomingStopsWhenNothingOlderComes() async throws {
        let server = FakeTodosServer()
        await server.setUpcomingOldestBack(100)
        let clock = TodosTestClock("2026-11-26T10:00:00+01:00")
        let store = TodosStore(storage: InMemoryTodosStorage(), scheduler: HeldScheduler(), now: { clock.now })
        store.connect(server)
        await store.loadUpcoming()
        XCTAssertEqual(store.upcoming?.earlier.count, 1)

        await store.loadEarlierUpcoming()
        XCTAssertEqual(store.upcoming?.earlier.first?.date, "2026-09-01")
        XCTAssertFalse(store.upcomingBackDone)

        await store.loadEarlierUpcoming()
        XCTAssertTrue(store.upcomingBackDone)
        let asked = await server.upcomingAsks
        await store.loadEarlierUpcoming()
        let askedAfter = await server.upcomingAsks
        XCTAssertEqual(asked, [30, 120, 210])
        XCTAssertEqual(askedAfter, asked)
    }

    func testDaysRepeatsAndNudgesAreSaidAsOnTheWeb() async throws {
        let vectors = try vectors()
        for case_ in array(vectors["headings"]) {
            let fields = object(case_)
            guard case .string(let date) = fields["date"] else { return XCTFail("date") }
            let heading = TodoWords.dayHeading(date, today: "2026-11-26")
            XCTAssertEqual(
                PaiJSONValue.object(["label": .string(heading.label), "sub": .string(heading.sub)]), fields["heading"],
                date)
        }
        for case_ in array(vectors["quickDays"]) {
            let fields = object(case_)
            guard case .string(let today) = fields["today"] else { return XCTFail("today") }
            let days = array(fields["days"]).map { day -> String in
                guard case .string(let label) = object(day)["label"], case .string(let date) = object(day)["date"]
                else {
                    return ""
                }
                return "\(label) \(date)"
            }
            XCTAssertEqual(TodoWords.quickDays(today).map { "\($0.label) \($0.date)" }, days, today)
        }
        for case_ in array(vectors["repeats"]) {
            XCTAssertEqual(
                PaiJSONValue.string(TodoWords.repeatRule(object(object(case_)["repeat"]))), object(case_)["text"])
        }
        for case_ in array(vectors["nudges"]) {
            let nudge = object(object(case_)["nudge"])
            func text(_ key: String) -> String? { if case .string(let value) = nudge[key] { value } else { nil } }
            var minutes: Int?
            if case .number(let value) = nudge["offset_minutes"] { minutes = NSDecimalNumber(decimal: value).intValue }
            let said = TodoWords.nudge(
                kind: text("kind") ?? "", date: text("date"), time: text("time"), basis: text("basis"),
                offsetMinutes: minutes)
            XCTAssertEqual(PaiJSONValue.string(said), object(case_)["text"])
        }
        for case_ in array(vectors["states"]) {
            let fields = object(case_)
            let state = try model(TodoNudgeState.self, fields["state"])
            var fireAt: String?
            if case .string(let value) = fields["fire_at"] { fireAt = value }
            let said = TodoWords.nudgeState(state, fireAt: fireAt)
            XCTAssertEqual(
                PaiJSONValue.object(["label": .string(said.label), "tone": .string(said.tone.rawValue)]),
                fields["described"])
        }
    }

    func testAFieldChoiceSendsTheWebsOp() async throws {
        let ops = object(try vectors()["fieldOps"])
        func first(_ key: String) -> PaiJSONValue? { array(ops[key]).first }
        XCTAssertEqual(PaiJSONValue.object(TodoFieldOps.when("t", date: "2026-11-28").fields), first("when"))
        XCTAssertEqual(
            PaiJSONValue.object(TodoFieldOps.when("t", date: "2026-11-28", time: "17:00").fields), first("whenTime"))
        XCTAssertEqual(PaiJSONValue.object(TodoFieldOps.when("t", date: nil).fields), first("whenClear"))
        XCTAssertEqual(PaiJSONValue.object(TodoFieldOps.deadline("t", date: "2026-12-03").fields), first("deadline"))
        XCTAssertEqual(PaiJSONValue.object(TodoFieldOps.deadline("t", date: nil).fields), first("deadlineClear"))
        let weekly = TodoFieldOps.withUnit(TodoFieldOps.defaultRepeat, "week")
        var friday = weekly
        friday["mode"] = .string("schedule")
        friday["on"] = .object(["weekdays": .array([.number(5)])])
        friday["anchor_day"] = nil
        friday.removeValue(forKey: "anchor_day")
        XCTAssertEqual(PaiJSONValue.object(TodoFieldOps.toggleWeekday(friday, 2)).compared, ops["weekdayOn"]?.compared)
        XCTAssertEqual(
            PaiJSONValue.object(TodoFieldOps.toggleWeekday(friday, 5)).compared, ops["weekdayLast"]?.compared)
        var anchored = friday
        anchored["anchor_day"] = .number(3)
        XCTAssertEqual(PaiJSONValue.object(TodoFieldOps.withUnit(anchored, "month")), ops["unit"])
        XCTAssertEqual(PaiJSONValue.object(TodoFieldOps.defaultRepeat), ops["defaultRepeat"])

        let overlay = object(try vectors()["overlay"])
        let existing = try model([TodoNudge].self, overlay["existing"])
        let queued = try model([TodoOp].self, overlay["ops"])
        let drawn = TodoWords.overlayNudges(existing, ops: queued, todoId: "t")
        XCTAssertEqual(drawn.map(\.id), try model([TodoNudge].self, overlay["out"]).map(\.id))
    }

    /// A card moved on the desk sends the op the web's drop sends: down lands after the card it is
    /// over, up before it, a section moves by its own id.
    func testADeskReorderSendsTheWebsOp() async throws {
        let moves = object(try vectors()["deskMoves"])
        let desk = try model([TodoDeskItem].self, moves["desk"])
        let cases = array(moves["moves"])
        XCTAssertEqual(cases.count, 25)
        for case_ in cases {
            let fields = object(case_)
            guard case .number(let from) = fields["from"], case .number(let over) = fields["over"] else {
                return XCTFail("indices")
            }
            let op = TodoDeskArrange.move(
                desk, from: NSDecimalNumber(decimal: from).intValue, over: NSDecimalNumber(decimal: over).intValue)
            XCTAssertEqual(op.map { PaiJSONValue.object($0.fields) } ?? .null, fields["op"], "\(from) over \(over)")
        }
        // Dragging the first card below the second, as `onMove` reports it, is "after the second".
        XCTAssertEqual(
            TodoDeskArrange.onMove(desk, from: 0, to: 2)?.fields["position"], .object(["after": .string("t2")]))
        XCTAssertEqual(
            TodoDeskArrange.onMove(desk, from: 3, to: 0)?.fields["position"], .object(["before": .string("t1")]))
    }

    /// What is typed into search goes out as the web's box sends it.
    func testATypedSearchIsTheWebsRequest() async throws {
        let encoded = try JSONDecoder().decode(
            PaiJSONValue.self, from: JSONEncoder().encode(TodosSearchRequest(q: "tag:home kestrel")))
        XCTAssertEqual(
            encoded, .object(["q": .string("tag:home kestrel"), "as_you_type": .bool(true), "status": .string("auto")]))
        let server = FakeTodosServer()
        let store = TodosStore(storage: InMemoryTodosStorage(), scheduler: HeldScheduler())
        store.connect(server)
        _ = try await store.search(TodosSearchRequest(q: "kestrel"))
        let sent = await server.searched
        XCTAssertEqual(sent.map(\.q), ["kestrel"])
    }

    /// A field edited in the sheet is a change in the outbox, drawn at once; a subtask added there
    /// stays under its parent from the moment it is typed until a read of the parent holds it.
    func testASheetEditGoesThroughTheOutboxAndANewSubtaskNeverBlinksOut() async throws {
        let server = FakeTodosServer()
        let parent = "11111111-0000-7000-8000-0000000000b1"
        try await server.seed(id: parent, title: "Plan the trip")
        let clock = TodosTestClock("2026-11-26T10:00:00+01:00")
        let store = TodosStore(storage: InMemoryTodosStorage(), scheduler: HeldScheduler(), now: { clock.now })
        store.connect(server)
        await store.refresh()
        await store.loadSheet(parent)

        await server.set(network: .down)
        let rename = try XCTUnwrap(TodoFieldOps.title(parent, "  Plan the   coast trip "))
        store.submit([rename])
        await store.drain()
        XCTAssertEqual(store.todos[parent]?.title, "Plan the coast trip")

        let child = TodosStore.uuidv7()
        store.submit([TodoFieldOps.subtask(id: child, parent: parent, title: "Book the ferry")])
        XCTAssertEqual(store.sheetChildren(of: parent), [child], "drawn before the server has it")

        await server.set(network: .up)
        store.retryNow()
        await store.drain()
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.todos[parent]?.title, "Plan the coast trip", "the answer's row carries the field")
        XCTAssertEqual(store.sheetChildren(of: parent), [child], "applied, not yet read: still drawn")
        await store.loadSheet(parent)
        XCTAssertEqual(store.sheetChildren(of: parent), [child])
    }
}

extension PaiJSONValue {
    /// The value with keys whose value is null left out, for rules that write `null` where the
    /// other side leaves the key away.
    fileprivate var compared: PaiJSONValue {
        guard case .object(let fields) = self else { return self }
        return .object(fields.filter { $0.value != .null }.mapValues(\.compared))
    }
}
