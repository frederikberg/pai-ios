import Foundation
import XCTest

@testable import PAIKit

/// Horizon marks, nested tag names, default and days-before nudges, "no date" and adding by plain
/// words, checked against what the web app's own functions answer for the same inputs
/// (`Resources/todos/web-parity-vectors.json`) and against answers captured from a server.
@MainActor
final class TodosParityTests: XCTestCase {

    private func vectors() throws -> [String: PaiJSONValue] {
        try TodosWireSamples.decode([String: PaiJSONValue].self, "web-parity-vectors")
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

    private func strings(_ value: PaiJSONValue?) -> [String] { array(value).compactMap(\.stringValue) }

    private func makeStore() -> TodosStore {
        let clock = TodosTestClock("2026-11-27T10:00:00+01:00")
        return TodosStore(storage: InMemoryTodosStorage(), now: { clock.now })
    }

    /// The chip as the web's vector writes it.
    private func web(_ chip: TodoAddChip) -> PaiJSONValue {
        var fields: [String: PaiJSONValue] = [
            "key": .string(chip.key), "kind": .string(chip.kind), "label": .string(chip.label),
        ]
        if let color = chip.color { fields["color"] = .string(color.rawValue) }
        if let dismissKey = chip.dismissKey { fields["fromView"] = .object(["dismissKey": .string(dismissKey)]) }
        return .object(fields)
    }

    func testHorizonsAndNestedTagsLookAsOnTheWeb() async throws {
        let vectors = try vectors()
        let horizons = array(vectors["horizons"])
        XCTAssertEqual(horizons.count, 4)
        for case_ in horizons {
            let fields = object(case_)
            let horizon = try XCTUnwrap(TodoHorizon.knownValues[fields["horizon"]?.stringValue ?? ""])
            let mark = TodoHorizonMark.of(horizon)
            XCTAssertEqual(mark.label, fields["label"]?.stringValue)
            XCTAssertEqual(mark.color.rawValue, fields["color"]?.stringValue)
        }
        for case_ in array(vectors["leaves"]) {
            let fields = object(case_)
            let name = fields["name"]?.stringValue ?? ""
            XCTAssertEqual(TodoIdentity.tagLeaf(name), fields["leaf"]?.stringValue, name)
        }
    }

    /// A nudge in either form reads as the web says it, in the list and on the When line, and the
    /// days-before choice becomes the op the web sends.
    func testNudgesOfEitherFormReadAndAreSentAsOnTheWeb() async throws {
        let vectors = try vectors()
        let cases = array(vectors["nudges"])
        XCTAssertGreaterThan(cases.count, 10)
        for case_ in cases {
            let fields = object(case_)
            var nudge = object(fields["nudge"])
            nudge["id"] = .string("N")
            nudge["todo_id"] = .string("T")
            nudge["origin"] = .null
            nudge["fire_at"] = .null
            nudge["state"] = .string("armed")
            let read = try model(TodoNudge.self, .object(nudge))
            XCTAssertEqual(TodoWords.nudge(read), fields["describe"]?.stringValue)
            XCTAssertEqual(TodoWords.nudgeShort(read), fields["short"]?.stringValue)
        }
        for case_ in array(vectors["ops"]) {
            let fields = object(case_)
            let choice = object(fields["choice"])
            let kind = choice["kind"]?.stringValue
            let ours: TodoFieldOps.NudgeChoice
            switch kind {
            case "days":
                ours = .days(
                    basis: choice["basis"]?.stringValue ?? "", days: choice["days"]?.intValue ?? -99,
                    time: choice["time"]?.stringValue ?? "")
            case "before":
                ours = .before(basis: choice["basis"]?.stringValue ?? "", minutes: choice["minutes"]?.intValue ?? -99)
            default:
                ours = .at(date: choice["date"]?.stringValue ?? "", time: choice["time"]?.stringValue ?? "")
            }
            XCTAssertEqual(.object(TodoFieldOps.nudgeSet("T1", ours, id: "N1").fields), fields["op"], kind ?? "")
        }
        // A queued days-before nudge is drawn with its days and its time before the server answers.
        let queued = TodoFieldOps.nudgeSet("T1", .days(basis: "when", days: 1, time: "17:00"), id: "N1")
        let drawn = TodoWords.overlayNudges([], ops: [queued], todoId: "T1")
        let web = try model([TodoNudge].self, vectors["overlay"])
        XCTAssertEqual(drawn, web)
        XCTAssertEqual(TodoWords.nudge(try XCTUnwrap(drawn.first)), "1 day before the day at 17:00")
    }

    /// The add sheet's chips: what the line read, the open view's defaults, "No date".
    func testTheAddSheetChipsAreTheWebs() async throws {
        let vectors = try vectors()
        let read = array(vectors["chips"])
        XCTAssertEqual(read.count, 4)
        for case_ in read {
            let fields = object(case_)
            let answer = try model(TodosParseAnswer.self, fields["answer"])
            XCTAssertEqual(TodoAddChip.read(answer, today: "2026-11-27").map(web), array(fields["chips"]))
        }
        for case_ in array(vectors["defaults"]) {
            let fields = object(case_)
            let defaults: TodoViewDefaults? =
                fields["defaults"] == .null ? nil : try model(TodoViewDefaults.self, fields["defaults"])
            let chips = TodoAddChip.defaults(
                defaults, dismissed: Set(strings(fields["dismissed"])), listName: { $0 == "L1" ? "Personal" : nil })
            XCTAssertEqual(chips.map(web), array(fields["chips"]))
        }
    }

    /// "No date" in the line drops the view's day as a dismissal would, and a dismissed default
    /// stays off the todo made.
    func testNoDateAndDismissedDefaultsLeaveTheViewsValuesOff() async throws {
        let vectors = try vectors()
        for case_ in array(vectors["cleared"]) {
            let fields = object(case_)
            let answer: TodosParseAnswer? =
                fields["answer"] == .null ? nil : try model(TodosParseAnswer.self, fields["answer"])
            let gone = TodoCreate.cleared(Set(strings(fields["dismissed"])), answer: answer)
            XCTAssertEqual(gone.sorted(), strings(fields["gone"]))
        }
        let creates = array(vectors["creates"])
        XCTAssertEqual(creates.count, 3)
        for case_ in creates {
            let input = object(object(case_)["input"])
            let defaults = try model(TodoViewDefaults.self, input["defaults"])
            let place = TodoCreatePlace(defaults: defaults, listId: input["listId"]?.stringValue)
            let op = TodoCreate.op(
                id: "n1", title: input["title"]?.stringValue ?? "", place: place,
                today: input["today"]?.stringValue, typed: object(input["typed"]),
                dismissed: Set(strings(input["dismissed"])))
            XCTAssertEqual(.object(op.fields), object(case_)["op"])
        }
    }

    /// Words added on Today that say "no date" make a todo without Today's day, whether the
    /// sheet had the parser's answer at hand or the words were read when the change went out.
    func testNoDateOnTodayMakesATodoWithoutADay() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()
        let today = TodoCreatePlace(
            defaults: try model(TodoViewDefaults.self, .object(["when": .string("today")])), listId: nil)
        let answer = try TodosWireSamples.decode(TodosParseAnswer.self, "parse-no-date")

        let atHand = store.capture(text: "Dune no date", place: today, parsed: answer)
        let readLater = store.capture(text: "Dune no date", place: today)
        let plain = store.capture(text: "Dune", place: today)
        for change in [atHand, readLater, plain] {
            guard case .applied = await store.settled(change, timeout: 30) else { return XCTFail("not applied") }
        }
        let made = await server.createdOps
        let ops = made.values.sorted { ($0.string("title") ?? "") < ($1.string("title") ?? "") }
        XCTAssertEqual(ops.count, 3)
        XCTAssertEqual(ops.filter { $0.fields["when"] == nil }.count, 2)
        XCTAssertNotNil(ops.first { $0.fields["when"] != nil }, "a line without 'no date' keeps Today's day")
        // A default the person tapped off stays off, and goes out with the capture.
        let dismissed = store.capture(text: "Dune", place: today, dismissed: ["when"])
        guard case .applied = await store.settled(dismissed, timeout: 30) else { return XCTFail("not applied") }
        let all = await server.createdOps
        XCTAssertEqual(all.values.filter { $0.fields["when"] == nil }.count, 3)
    }

    /// The model's todos laid over the view's defaults exactly as the web lays them.
    func testComposedTodosTakeTheViewsDefaultsAsOnTheWeb() async throws {
        let vectors = try vectors()
        let cases = array(vectors["composed"])
        XCTAssertEqual(cases.count, 2)
        for case_ in cases {
            let fields = object(case_)
            let input = object(fields["input"])
            let defaults: TodoViewDefaults? =
                input["defaults"] == .null ? nil : try model(TodoViewDefaults.self, input["defaults"])
            let ops = try model([TodoOp].self, fields["ops"])
            let place = TodoCreatePlace(defaults: defaults, listId: input["listId"]?.stringValue)
            let out = TodoCreate.withViewDefaults(ops, place: place, today: input["today"]?.stringValue)
            XCTAssertEqual(PaiJSONValue.array(out.map { .object($0.fields) }), fields["out"])
        }
    }

    /// Plain words become every todo the model read, subtasks under their parent, in ONE change,
    /// with the first todo named for opening. Nothing is queued when the model reads nothing or
    /// cannot be reached; the plain path still keeps a door's words.
    func testPlainWordsBecomeOneChangeAndAFailureQueuesNothing() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()

        let sample = try TodosWireSamples.decode(TodosComposeAnswer.self, "compose")
        let captured = try XCTUnwrap(sample.ops.first)
        func create(_ id: String, _ title: String, parent: String? = nil) -> TodoOp {
            var op = captured.setting("id", .string(id)).setting("title", .string(title))
            if let parent { op = op.setting("parent", .string(parent)) }
            return op
        }
        let parent = "0190f000-0000-7000-8000-0000000000c1"
        await server.setCompose(
            TodosComposeAnswer(
                ops: [
                    create(parent, "Call the plumber"),
                    create("0190f000-0000-7000-8000-0000000000c2", "Ask about the boiler", parent: parent),
                    create("0190f000-0000-7000-8000-0000000000c3", "Buy stamps"),
                ], model: "rig"))
        let place = TodoCreatePlace(
            defaults: try model(TodoViewDefaults.self, .object(["tags": .array([.string("home")])])), listId: nil)
        let applyCallsBefore = await server.applyCalls

        let composed = try await store.compose(text: "Call the plumber, ask about the boiler, buy stamps", place: place)
        XCTAssertEqual(composed.firstTodoId, parent)
        XCTAssertEqual(composed.count, 3)
        guard case .applied = await store.settled(composed.changeId, timeout: 30) else { return XCTFail("not applied") }
        let applyCalls = await server.applyCalls
        XCTAssertEqual(applyCalls - applyCallsBefore, 1, "one change")
        let made = await server.todos
        XCTAssertEqual(made[parent]?.tags, ["home"])
        XCTAssertEqual(made["0190f000-0000-7000-8000-0000000000c2"]?.parentId, parent)

        await server.setCompose(nil, refuses: true)
        do {
            _ = try await store.compose(text: "something", place: place)
            XCTFail("a model that did not answer is a failure")
        } catch let failure as TodosComposeFailure {
            XCTAssertEqual(failure, .unread)
        }
        await server.setCompose(TodosComposeAnswer(ops: [], model: "rig"))
        do {
            _ = try await store.compose(text: "hmm", place: place)
            XCTFail("an answer with no todo is a failure")
        } catch let failure as TodosComposeFailure {
            XCTAssertEqual(failure, .unread)
        }
        XCTAssertTrue(store.queue.isEmpty)

        await server.setCompose(nil)
        await server.set(network: .down)
        do {
            _ = try await store.compose(text: "something", place: place)
            XCTFail("no network is a failure")
        } catch let failure as TodosComposeFailure {
            XCTAssertEqual(failure, .unreachable)
        }
        XCTAssertTrue(store.queue.isEmpty)
        // A door that reports back keeps the words as typed when the model cannot be asked.
        let kept = await store.describeAndWait(text: "Water the plants", source: .shortcut, timeout: 0.5)
        XCTAssertFalse(kept.added)
        XCTAssertEqual(store.queue.count, 1)
        XCTAssertEqual(store.queue.first?.capture?.text, "Water the plants")
    }

    /// Answers captured from a server with default nudges set: the settings, a nudge they made
    /// (days before, with its origin), "no date" and a composed todo all read.
    func testDefaultNudgesAndComposeAnswersDecode() async throws {
        let me = try TodosWireSamples.decode(TodosMeAnswer.self, "me-default-nudges")
        let defaults = try XCTUnwrap(me.prefs?.defaultNudges)
        XCTAssertFalse(defaults.isEmpty)
        XCTAssertNotNil(defaults.day.first?.days)
        let detail = try TodosWireSamples.decode(TodosDetailAnswer.self, "detail-default-nudges")
        XCTAssertFalse(detail.nudges.isEmpty)
        XCTAssertTrue(detail.nudges.allSatisfy { $0.isDefault && $0.days != nil && $0.time != nil })
        XCTAssertTrue(TodoFieldOps.offersDefaults(detail.todo, prefs: me.prefs))
        XCTAssertEqual(try TodosWireSamples.decode(TodosParseAnswer.self, "parse-no-date").clears, ["when"])
        let composed = try TodosWireSamples.decode(TodosComposeAnswer.self, "compose")
        XCTAssertEqual(composed.ops.first?.name, "todo.create")
        // The older capture without default nudges still reads, and offers none.
        let older = try TodosWireSamples.decode(TodosMeAnswer.self, "me")
        XCTAssertFalse(TodoFieldOps.offersDefaults(detail.todo, prefs: older.prefs))
    }

    /// A link to Todos from another app lands where the web's address says: the home, a view, a
    /// list, a todo by its permanent link or opened over a page; a nudge's push opens its todo.
    func testTodosLinksAndNudgePushesOpenWhereTheWebsAddressSays() async throws {
        func link(_ path: String) -> DeepLink? {
            DeepLink.from(webURL: URL(string: "https://pai.example.org\(path)")!)
        }
        XCTAssertEqual(link("/apps/todos"), .todos(page: nil, todo: nil))
        XCTAssertEqual(link("/apps/todos/"), .todos(page: nil, todo: nil))
        XCTAssertEqual(link("/apps/todos/t/12"), .todos(page: nil, todo: 12))
        XCTAssertEqual(link("/apps/todos/v/0190f000-aaaa"), .todos(page: .view("0190f000-aaaa"), todo: nil))
        XCTAssertEqual(link("/apps/todos/l/0190f000-bbbb?t=7"), .todos(page: .list("0190f000-bbbb"), todo: 7))
        XCTAssertEqual(link("/apps/todos/?t=3"), .todos(page: nil, todo: 3))
        XCTAssertEqual(link("/apps/todos/settings/nudges?t=4"), .todos(page: nil, todo: 4))
        XCTAssertEqual(link("/apps/todos/t/0"), .todos(page: nil, todo: nil))
        XCTAssertEqual(link("/apps/todos/t/-2"), .todos(page: nil, todo: nil))
        XCTAssertEqual(link("/apps/todos/l"), .todos(page: nil, todo: nil))
        XCTAssertEqual(link("/apps/todosx"), nil)
        XCTAssertEqual(DeepLink.todos(page: .list("L"), todo: 7).routes, [.todosPage(.list("L"))])
        XCTAssertTrue(DeepLink.todos(page: nil, todo: 7).dismissesOverlays)
        XCTAssertFalse(DeepLink.todosHome.dismissesOverlays)

        XCTAssertEqual(DeepLink.from(payload: ["pai_todo_number": "12"]), .todos(page: nil, todo: 12))
        XCTAssertNil(DeepLink.from(payload: ["pai_todo_number": "x"]))
        XCTAssertEqual(DeepLink.from(url: try XCTUnwrap(DeepLink.describeTodo.url)), .describeTodo)

        // The number a link carries finds its todo, held or read from the server.
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()
        let changeId = store.capture(text: "Water the plants")
        guard case .applied = await store.settled(changeId, timeout: 30) else { return XCTFail("not applied") }
        let made = await server.todos
        let todo = try XCTUnwrap(made.values.first)
        let found = await store.todoId(number: try XCTUnwrap(todo.number))
        XCTAssertEqual(found, todo.id)
        let unknown = await store.todoId(number: 9999)
        XCTAssertNil(unknown)
    }
}
