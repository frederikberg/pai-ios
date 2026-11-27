import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@MainActor
final class TodosEntryTests: XCTestCase {

    private func makeStore(_ storage: any TodosStorage = InMemoryTodosStorage()) -> TodosStore {
        let clock = TodosTestClock("2026-11-26T10:00:00+01:00")
        return TodosStore(storage: storage, scheduler: HeldScheduler(), now: { clock.now })
    }

    /// The words the sheet dims are the words the server moves: `title-split-vectors.json` holds
    /// what the server's own `titles.split` answered for each line.
    func testATitleIsCutWhereTheServerCutsIt() async throws {
        struct Case: Decodable {
            let name: String
            let text: String
            let title: String
            let rest: String
        }
        let cases = try TodosWireSamples.decode([Case].self, "title-split-vectors")
        XCTAssertGreaterThanOrEqual(cases.count, 9)
        for case_ in cases {
            let split = TodoTitles.split(case_.text)
            XCTAssertEqual(split.title, case_.title, case_.name)
            XCTAssertEqual(split.rest, case_.rest, case_.name)
            let dimmed = TodoTitles.overflow(of: case_.text)
            XCTAssertEqual(dimmed.isEmpty, case_.rest.isEmpty, case_.name)
            if let first = dimmed.first {
                let units = Array(case_.text.utf16)
                let moved = String(decoding: units[first.lowerBound...], as: UTF16.self)
                XCTAssertEqual(moved.trimmingCharacters(in: .whitespacesAndNewlines), case_.rest, case_.name)
            }
        }
    }

    /// A word the parser reads as a field is no part of the title: it neither counts towards the
    /// limit nor is shown as moving.
    func testAFieldWordNeitherCountsNorMoves() async throws {
        let filler = String(repeating: "word ", count: 97)
        let text = "tomorrow " + filler + "abcd tail"
        let token = TodoParseToken(start: 0, end: 8, kind: "when", value: .null, display: "Tomorrow")
        XCTAssertFalse(TodoTitles.overflow(of: text).isEmpty, "counted whole, the line is too long")
        XCTAssertTrue(TodoTitles.overflow(of: text, tokens: [token]).isEmpty, "without the day it fits")
    }

    /// What is typed into a sheet is on the device while the sheet holds it: a second launch
    /// finds the words, the description and the picks; sending or discarding takes them away.
    func testATypedDraftOutlivesTheProcess() async throws {
        let storage = SettingsInMemoryKeyValueStore()
        let drafts = TodoEntryDrafts(storage: storage)
        var draft = drafts.draft(for: TodoEntryDrafts.pageKey)
        XCTAssertTrue(draft.isEmpty)
        draft.text = "Ask about the cellar key"
        draft.description = "Before the neighbours move in"
        draft.picks.horizon = .week
        drafts.keep(draft, for: TodoEntryDrafts.pageKey)
        var sub = TodoEntryDraft()
        sub.text = "Pack the charger"
        drafts.keep(sub, for: TodoEntryDrafts.subtaskKey(parent: "p1"))

        let relaunched = TodoEntryDrafts(storage: storage)
        XCTAssertEqual(relaunched.draft(for: TodoEntryDrafts.pageKey), draft)
        XCTAssertEqual(relaunched.draft(for: TodoEntryDrafts.subtaskKey(parent: "p1")).text, "Pack the charger")
        XCTAssertTrue(relaunched.draft(for: TodoEntryDrafts.subtaskKey(parent: "p2")).isEmpty, "one entry per sheet")

        relaunched.keep(TodoEntryDraft(), for: TodoEntryDrafts.pageKey)
        XCTAssertTrue(TodoEntryDrafts(storage: storage).draft(for: TodoEntryDrafts.pageKey).isEmpty, "sent: gone")
        relaunched.discard(TodoEntryDrafts.subtaskKey(parent: "p1"))
        XCTAssertTrue(TodoEntryDrafts(storage: storage).draft(for: TodoEntryDrafts.subtaskKey(parent: "p1")).isEmpty)
    }

    /// Closing asks only when words would be lost: a title or a description, never spaces alone
    /// and never a sheet that holds nothing but a picked field.
    func testClosingAsksOnlyWhenWordsWereTyped() async throws {
        var draft = TodoEntryDraft()
        XCTAssertFalse(draft.holdsWords)
        draft.text = "  \n "
        XCTAssertFalse(draft.holdsWords)
        draft.picks.horizon = .now
        XCTAssertFalse(draft.holdsWords)
        XCTAssertFalse(draft.isEmpty, "a pick alone is still kept while the sheet is open")
        draft.description = "note to self"
        XCTAssertTrue(draft.holdsWords)
        draft.description = ""
        draft.text = "Buy stamps"
        XCTAssertTrue(draft.holdsWords)
    }

    /// A sheet's todo goes out as typed, however long, with the pickers' choices over the
    /// line's and the view's, and the description under whatever the line put in the body.
    func testASheetsTodoCarriesItsPicksAndItsWholeLine() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()
        let answer = try TodosWireSamples.decode(TodosParseAnswer.self, "parse-fields")
        let typedDay = try XCTUnwrap(answer.fields.when?.date)
        var picks = TodoAddDraft()
        picks.when = TodoWhen(date: "2026-12-24", time: "18:00")
        picks.tags = ["gift"]
        picks.horizon = .soon
        let defaults = try JSONDecoder().decode(
            TodoViewDefaults.self, from: Data(#"{"tags":["errand"],"horizon":"week"}"#.utf8))
        let long = String(repeating: "word ", count: 130) + "end"
        let changeId = store.capture(
            text: long, place: TodoCreatePlace(defaults: defaults, listId: nil), parsed: answer,
            description: "Second thoughts", picks: picks)
        let settlement = await store.settled(changeId, timeout: 5)
        guard case .applied = settlement else { return XCTFail("\(settlement)") }
        let created = await server.createdOps
        let sent = try XCTUnwrap(created.values.first)
        XCTAssertNotEqual(typedDay, "2026-12-24", "the sample's own day differs from the picked one")
        XCTAssertEqual(sent.object("when")?.string("date"), "2026-12-24", "the picked day replaces the typed one")
        XCTAssertEqual(sent.string("horizon"), "soon", "and the picked horizon the view's")
        let tags = try XCTUnwrap(sent.strings("tags"))
        XCTAssertTrue(tags.contains("errand") && tags.contains("gift"), "tags add up: \(tags)")
        XCTAssertTrue(sent.string("body")?.hasSuffix("Second thoughts") == true)
    }

    /// A line the parser was never asked about goes out whole: nothing is cut on the phone.
    func testALongLineIsNeverCutOnThePhone() async throws {
        let store = makeStore()
        let long = String(repeating: "word ", count: 130) + "end"
        store.capture(text: long)
        XCTAssertEqual(store.queue.first?.capture?.text, long)
        XCTAssertNil(store.queue.first?.capture?.body)
    }

    /// "Add here" under a section: the new todo lands at that section's end, not at the desk's.
    func testATodoAddedIntoASectionLandsAtItsEnd() async throws {
        let server = FakeTodosServer()
        try await server.seed(id: "11111111-0000-7000-8000-0000000000a1", title: "Top card")
        try await server.seed(id: "11111111-0000-7000-8000-0000000000a2", title: "Evening card")
        let store = makeStore()
        store.connect(server)
        await store.refresh()
        let divider = "11111111-0000-7000-8000-0000000000d1"
        store.submit([
            .deskAdd(todo: "11111111-0000-7000-8000-0000000000a1"),
            TodoFieldOps.deskSection(id: divider, title: "Evening"),
            .deskAdd(todo: "11111111-0000-7000-8000-0000000000a2"),
        ])
        await store.drain()
        XCTAssertEqual(store.deskItems.count, 3)

        let answer = try TodosWireSamples.decode(TodosParseAnswer.self, "parse-plain")
        let top = TodoDeskSections.end(of: nil, in: store.deskItems)
        let changeId = store.capture(text: answer.title, parsed: answer, deskPosition: top)
        let made = try XCTUnwrap(store.createdTodoId(ofChange: changeId))
        XCTAssertEqual(store.deskItems.map { $0.todoId ?? $0.id }.firstIndex(of: made), 1, "drawn there at once")
        _ = await store.settled(changeId, timeout: 5)
        await store.drain()
        let desk = await server.desk.map { $0.todoId ?? $0.id }
        XCTAssertEqual(
            desk, ["11111111-0000-7000-8000-0000000000a1", made, divider, "11111111-0000-7000-8000-0000000000a2"])
        XCTAssertEqual(
            TodoDeskSections.end(of: divider, in: store.deskItems), .after("11111111-0000-7000-8000-0000000000a2"))
    }

    /// A file picked for a todo the queue is still to create waits with it, on the phone, and
    /// goes up before the change that names it; its bytes leave the phone once the server has them.
    func testAFileOnAQueuedTodoGoesUpAfterTheTodoAndBeforeItsAttachment() async throws {
        let server = FakeTodosServer()
        let storage = InMemoryTodosStorage()
        let store = makeStore(storage)
        store.connect(server)
        await store.refresh()
        await server.set(network: .down)
        let answer = try TodosWireSamples.decode(TodosParseAnswer.self, "parse-plain")
        let create = store.capture(text: answer.title, parsed: answer)
        let todoId = try XCTUnwrap(store.createdTodoId(ofChange: create))
        let bytes = Data("not really a picture".utf8)
        let attach = try XCTUnwrap(
            store.attach(todoId: todoId, name: "photo.jpg", contentType: "image/jpeg", data: bytes))
        await store.drain()
        let hash = TodoBlobs.sha256Hex(bytes)
        XCTAssertEqual(store.queuedFiles(of: todoId).map(\.name), ["photo.jpg"])
        XCTAssertEqual(storage.loadBlob(sha256: hash), bytes, "kept while there is no connection")
        let before = await server.blobs
        XCTAssertTrue(before.isEmpty)

        // A second launch still holds both the change and the bytes.
        let relaunched = makeStore(storage)
        XCTAssertEqual(relaunched.queue.map(\.changeId), [create, attach])
        await server.set(network: .up)
        relaunched.connect(server)
        await relaunched.drain()
        let applied = await server.appliedLog
        XCTAssertEqual(applied, [create, attach])
        let attached = await server.attached
        XCTAssertEqual(attached.map(\.todo), [todoId])
        XCTAssertEqual(attached.map(\.blob), [hash])
        XCTAssertNil(storage.loadBlob(sha256: hash), "the bytes leave the phone once attached")
        XCTAssertTrue(relaunched.queuedFiles(of: todoId).isEmpty)
    }

    /// Red once past, yellow on the day, blue within seven days, plain beyond; a time of today
    /// that has passed is past.
    func testADateIsColouredByHowNearItIs() async throws {
        let today = "2026-11-27"
        XCTAssertEqual(TodoDates.light(date: "2026-11-26", today: today), .late)
        XCTAssertEqual(TodoDates.light(date: today, today: today), .today)
        XCTAssertEqual(TodoDates.light(date: today, time: "09:00", today: today, clock: "09:01"), .late)
        XCTAssertEqual(TodoDates.light(date: today, time: "09:00", today: today, clock: "09:00"), .today)
        XCTAssertEqual(TodoDates.light(date: "2026-11-28", time: "00:05", today: today, clock: "23:00"), .week)
        XCTAssertEqual(TodoDates.light(date: "2026-12-04", today: today), .week)
        XCTAssertEqual(TodoDates.light(date: "2026-12-05", today: today), .later)
        XCTAssertEqual(
            TodoDates.deadlineMark(TodoDeadline(date: "2026-11-24"), today: today),
            TodoDates.Mark(label: "3 d ago", light: .late))
    }
}
