import Foundation
import XCTest

@testable import PAIKit

/// A subtask line is read like an add sheet's line, and a horizon grouping is named, not keyed.
@MainActor
final class TodosSubtaskTests: XCTestCase {

    private func makeStore() -> TodosStore {
        let clock = TodosTestClock("2026-11-27T10:00:00+01:00")
        return TodosStore(storage: InMemoryTodosStorage(), now: { clock.now })
    }

    /// What the parser read in the line (here a horizon, a tag and a day) becomes the subtask's,
    /// under its parent, whether the answer was at hand or the line was read when it went out;
    /// nothing else is laid over it.
    func testASubtaskLineIsReadLikeATodoLine() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()
        let parent = "0190f000-0000-7000-8000-0000000000p1"
        let answer = try TodosWireSamples.decode(TodosParseAnswer.self, "parse-fields")
        let line = "Call the plumber tomorrow 17:00 #home p1"

        let atHand = store.capture(text: line, place: .under(parent: parent), parsed: answer)
        let readLater = store.capture(text: line, place: .under(parent: parent))
        for change in [atHand, readLater] {
            guard case .applied = await store.settled(change, timeout: 30) else { return XCTFail("not applied") }
        }
        let made = Array(await server.createdOps.values)
        XCTAssertEqual(made.count, 2)
        for op in made {
            XCTAssertEqual(op.string("parent"), parent)
            XCTAssertEqual(op.string("horizon"), "now")
            XCTAssertEqual(op.strings("tags"), ["home"])
            XCTAssertEqual(op.string("title"), answer.createOp.string("title"))
            XCTAssertNil(op.fields["list"], "a subtask lands in its parent's list")
            XCTAssertNil(op.fields["desk"])
        }
    }

    /// Grouped by horizon, a heading reads the horizon's name; grouped by tag, a tag that happens
    /// to be called "now" keeps its own name.
    func testAHorizonGroupIsNamedAndATagGroupIsNot() async throws {
        let template = try TodosWireSamples.decode(TodosQueryAnswer.self, "query-open").todos.first {
            $0.parentId == nil
        }!
        var other = template
        other.id = "other"
        let todos = [template.id: template, "other": other]
        let result = TodoPageResult(
            groups: [
                TodoQueryGroup(key: "now", label: "now", ids: [template.id]),
                TodoQueryGroup(key: "soon", label: "soon", ids: ["other"]),
            ], total: 2, nextCursor: nil, seq: 1)
        func headings(_ groupBy: String?) -> [String] {
            TodoRows.build(
                result: result, pending: [], todos: todos, expanded: [], children: [:], groupBy: groupBy
            ).compactMap {
                if case .heading(_, let label, _) = $0 { return label }
                return nil
            }
        }
        XCTAssertEqual(
            headings("horizon"), [TodoHorizonMark.of(.now).label, TodoHorizonMark.of(.soon).label])
        XCTAssertEqual(headings("tag"), ["now", "soon"])
    }
}
