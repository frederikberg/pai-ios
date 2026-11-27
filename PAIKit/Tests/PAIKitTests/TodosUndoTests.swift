import Foundation
import XCTest

@testable import PAIKit

/// Undo from a toast, a description saved when its screen is left, and the add sheet's chips and
/// taps. The tap words are checked against what the web app's own `insert` answers
/// (`Resources/todos/web-insert-vectors.json`).
@MainActor
final class TodosUndoTests: XCTestCase {

    private func makeStore() -> TodosStore {
        let clock = TodosTestClock("2026-11-27T10:00:00+01:00")
        return TodosStore(storage: InMemoryTodosStorage(), now: { clock.now })
    }

    /// A store connected to a fake server that holds one open todo the store has read.
    private func connected() async throws -> (TodosStore, FakeTodosServer, String) {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()
        let added = store.capture(text: "Water the plants")
        guard case .applied = await store.settled(added, timeout: 30) else { throw XCTSkip("not added") }
        let held = await server.todos
        let id = try XCTUnwrap(held.keys.first)
        return (store, server, id)
    }

    /// A tick the server applied is undone there: the todo is open again on both sides.
    func testATickTheServerAppliedIsUndone() async throws {
        let (store, server, id) = try await connected()
        let tick = try XCTUnwrap(store.toggleDone(todoId: id))
        guard case .applied = await store.settled(tick, timeout: 30) else { return XCTFail("not applied") }
        XCTAssertEqual(store.todos[id]?.status, .done)

        let outcome = await store.undo(changeId: tick)
        XCTAssertEqual(outcome, .undone)
        XCTAssertEqual(outcome.message, "Undone")
        let undone = await server.undone
        XCTAssertEqual(undone, [tick])
        let row = await server.todos[id]
        XCTAssertEqual(row?.status, .open)
        XCTAssertEqual(store.todos[id]?.status, .open)
    }

    /// Without a network a change never left the phone: Undo takes it out of the queue, and it
    /// is never sent. A later change than the one at the head is taken out the same way.
    func testAChangeThatNeverLeftThePhoneIsTakenOutOfTheQueue() async throws {
        let (store, server, id) = try await connected()
        await server.set(network: .down)
        let deskAdd = store.setOnDesk(todoId: id, true)
        let tick = try XCTUnwrap(store.toggleDone(todoId: id))
        await store.drain()
        XCTAssertEqual(store.todos[id]?.status, .done, "drawn from the queue")

        let outcome = await store.undo(changeId: tick)
        XCTAssertEqual(outcome, .undone)
        XCTAssertEqual(store.todos[id]?.status, .open)
        XCTAssertEqual(store.queue.map(\.changeId), [deskAdd])

        await server.set(network: .up)
        await store.drain()
        let log = await server.appliedLog
        XCTAssertTrue(log.contains(deskAdd))
        XCTAssertFalse(log.contains(tick))
        let row = await server.todos[id]
        XCTAssertEqual(row?.status, .open)
    }

    /// An Undo pressed while its change is on its way waits for the answer, then undoes it on the
    /// server, as the web's toast does.
    func testAnUndoWhileTheChangeIsBeingSentWaitsForIt() async throws {
        let (store, server, id) = try await connected()
        await server.holdApply()
        let tick = try XCTUnwrap(store.toggleDone(todoId: id))
        let sending = Task { await store.drain() }
        await server.waitForHeldApply()

        let undo = Task { await store.undo(changeId: tick) }
        await server.releaseApply()
        let outcome = await undo.value
        await sending.value
        XCTAssertEqual(outcome, .undone)
        let undone = await server.undone
        XCTAssertEqual(undone, [tick], "sent, then undone on the server")
        let row = await server.todos[id]
        XCTAssertEqual(row?.status, .open)
    }

    /// While the head of the queue is on its way, a later change has not left the phone: its
    /// Undo takes it out at once, and it is never sent.
    func testALaterChangeIsTakenOutWhileTheHeadIsBeingSent() async throws {
        let (store, server, id) = try await connected()
        await server.holdApply()
        let tick = try XCTUnwrap(store.toggleDone(todoId: id))
        let sending = Task { await store.drain() }
        await server.waitForHeldApply()
        let deskAdd = store.setOnDesk(todoId: id, true)

        let outcome = await store.undo(changeId: deskAdd)
        XCTAssertEqual(outcome, .undone)
        XCTAssertFalse(store.queue.contains { $0.changeId == deskAdd }, "taken out while the head is in flight")
        await server.releaseApply()
        await sending.value
        await store.drain()
        let log = await server.appliedLog
        XCTAssertTrue(log.contains(tick))
        XCTAssertFalse(log.contains(deskAdd))
        let undone = await server.undone
        XCTAssertEqual(undone, [])
    }

    /// Something changed since: the undo is refused and says so, and nothing is put back.
    func testAnUndoAfterALaterChangeSaysWhatStopsIt() async throws {
        let (store, server, id) = try await connected()
        let tick = try XCTUnwrap(store.toggleDone(todoId: id))
        guard case .applied = await store.settled(tick, timeout: 30) else { return XCTFail("not applied") }
        let rename = store.submit([TodoFieldOps.title(id, "Water the ferns")!])
        guard case .applied = await store.settled(rename, timeout: 30) else { return XCTFail("not applied") }

        let outcome = await store.undo(changeId: tick)
        XCTAssertEqual(outcome, .refused("Can't undo: 1 field was changed since."))
        let row = await server.todos[id]
        XCTAssertEqual(row?.status, .done)

        await server.set(network: .down)
        let offline = await store.undo(changeId: rename)
        XCTAssertEqual(offline, .failed)
        XCTAssertEqual(TodosUndoOutcome.failed.message, "Could not undo; try again.")
    }

    /// What the line names replaces the view's default in the todo made, so its chip goes; the
    /// chips shown are exactly the defaults the todo will carry.
    func testATypedFieldReplacesItsDefaultChip() async throws {
        let defaults = try JSONDecoder().decode(
            TodoViewDefaults.self,
            from: Data(
                #"{"tags":["errand"],"horizon":"soon","when":"today","desk":true,"list":"L1","parent":"P1"}"#.utf8))
        let place = TodoCreatePlace(defaults: defaults, listId: nil)
        let answers = try ["parse-fields", "parse-no-date", "parse-plain", "parse-list-desk"].map {
            try TodosWireSamples.decode(TodosParseAnswer.self, $0)
        }
        let fromView: [String: PaiJSONValue] = [
            "horizon": .string("soon"), "when": .object(["date": .string("2026-11-27")]), "desk": .bool(true),
            "list": .string("L1"), "parent": .string("P1"),
        ]
        for answer in answers {
            let shown = Set(
                TodoAddChip.defaults(
                    defaults, dismissed: TodoCreate.cleared([], answer: answer), typed: answer, listName: { _ in nil }
                )
                .compactMap(\.dismissKey))
            let op = TodoCreate.op(
                id: "n", title: answer.title, place: place, today: "2026-11-27", typed: TodoCreate.typed(from: answer),
                dismissed: TodoCreate.cleared([], answer: answer))
            let typed = TodoCreate.typed(from: answer)
            for (field, value) in fromView {
                // A line that names the same value as the view (`*` on a desk view) is the line's.
                let carriedFromView = op.fields[field] == value && typed[field] == nil
                XCTAssertEqual(shown.contains(field), carriedFromView, "\(field) for \(answer.title)")
            }
            XCTAssertTrue(shown.contains("tag:errand"), "tags add to the view's")
        }
        // On Today, "Call the plumber tomorrow 17:00 …" shows one day: the line's.
        let typedDay = try XCTUnwrap(answers.first)
        XCTAssertFalse(
            TodoAddChip.defaults(defaults, dismissed: [], typed: typedDay, listName: { _ in nil }).contains {
                $0.dismissKey == "when"
            })
    }

    func testTheTapsPutTheWebsWordsIntoTheLine() async throws {
        struct Vectors: Decodable {
            struct Pill: Decodable {
                let label: String
                let insert: String
            }
            struct Out: Decodable {
                let text: String
                let caret: Int
            }
            struct Case: Decodable {
                let text: String
                let caret: Int
                let piece: String
                let out: Out
            }
            let pills: [Pill]
            let inserts: [Case]
        }
        let vectors = try TodosWireSamples.decode(Vectors.self, "web-insert-vectors")
        XCTAssertEqual(TodoAddWords.taps.map(\.label), vectors.pills.map(\.label))
        XCTAssertEqual(TodoAddWords.taps.map(\.insert), vectors.pills.map(\.insert))
        XCTAssertGreaterThan(vectors.inserts.count, 50)
        for case_ in vectors.inserts {
            let out = TodoAddWords.insert(case_.piece, into: case_.text, at: case_.caret)
            XCTAssertEqual(out.text, case_.out.text, "\(case_.text)|\(case_.caret)|\(case_.piece)")
            XCTAssertEqual(out.caret, case_.out.caret, "\(case_.text)|\(case_.caret)|\(case_.piece)")
        }
    }
}
