import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@MainActor
final class TodosScreensTests: XCTestCase {

    /// Today opens split and every other list folded to the bar; each remembers its own state, on
    /// the device, apart from the other.
    func testTheDeskStateIsRememberedPerPageKind() async throws {
        let storage = SettingsInMemoryKeyValueStore()
        let modes = TodoDeskModes(storage: storage)
        XCTAssertEqual(modes.mode(for: .today), .split)
        XCTAssertEqual(modes.mode(for: .list), .bar)

        modes.set(.desk, for: .today)
        XCTAssertEqual(modes.mode(for: .list), .bar, "Today's state is its own")
        modes.set(.split, for: .list)

        let relaunched = TodoDeskModes(storage: storage)
        XCTAssertEqual(relaunched.mode(for: .today), .desk)
        XCTAssertEqual(relaunched.mode(for: .list), .split)
    }

    /// The built-in Today and any view laid out as Today are the Today page; everything else is a list.
    func testWhichPageIsToday() async throws {
        let views = try TodosWireSamples.decode(TodosMeAnswer.self, "me").views
        let today = try XCTUnwrap(views.first { $0.builtin == "today" })
        let all = try XCTUnwrap(views.first { $0.builtin == "all" })
        XCTAssertEqual(TodoDeskPageKind.of(view: today), .today)
        XCTAssertEqual(TodoDeskPageKind.of(view: all), .list)
        XCTAssertEqual(TodoDeskPageKind.of(view: nil), .list)
    }

    /// A page's rows: headings only for a grouped answer, todos made here first, and under an
    /// opened row its children, each openable in turn; a row not known is left out.
    func testAPagesRowsFoldChildrenUnderTheirParent() async throws {
        let template = try XCTUnwrap(try TodosWireSamples.decode(TodosQueryAnswer.self, "query-open").todos.first)
        func todo(_ id: String, children: Int = 0) -> Todo {
            var row = template
            row.id = id
            row.childrenOpen = children
            return row
        }
        let todos = [
            "a": todo("a", children: 1), "b": todo("b"), "c": todo("c", children: 1), "d": todo("d"), "n": todo("n"),
        ]
        let grouped = TodoPageResult(
            groups: [
                TodoQueryGroup(key: "now", label: "Now", ids: ["a", "b", "ghost"]),
                TodoQueryGroup(key: "soon", label: "Soon", ids: ["b"]),
            ], total: 2, nextCursor: nil, seq: 1)
        let rows = TodoRows.build(
            result: grouped, pending: ["n"], todos: todos, expanded: ["a", "c"], children: ["a": ["c"], "c": ["d"]])
        XCTAssertEqual(
            rows,
            [
                .heading(key: "now", label: "Now", count: 3),
                .todo(id: "n", depth: 0, expandable: false, expanded: false),
                .todo(id: "a", depth: 0, expandable: true, expanded: true),
                .todo(id: "c", depth: 1, expandable: true, expanded: true),
                .todo(id: "d", depth: 2, expandable: false, expanded: false),
                .todo(id: "b", depth: 0, expandable: false, expanded: false),
                .heading(key: "soon", label: "Soon", count: 1),
            ])

        let ungrouped = TodoPageResult(
            groups: [TodoQueryGroup(key: "all", label: "All", ids: ["b"])], total: 1, nextCursor: nil, seq: 1)
        XCTAssertEqual(
            TodoRows.build(result: ungrouped, pending: [], todos: todos, expanded: [], children: [:]),
            [.todo(id: "b", depth: 0, expandable: false, expanded: false)])
    }

    /// Ticking a subtask from its row is a change in the outbox: drawn at once, kept without a
    /// network, and sent once when it is back.
    func testTickingASubtaskFromItsRowGoesThroughTheOutbox() async throws {
        let server = FakeTodosServer()
        try await server.seed(id: "11111111-0000-7000-8000-0000000000a1", title: "Pack for the trip")
        try await server.seed(
            id: "11111111-0000-7000-8000-0000000000a2", title: "Socks", parent: "11111111-0000-7000-8000-0000000000a1")
        let clock = TodosTestClock("2026-11-26T10:00:00+01:00")
        let store = TodosStore(storage: InMemoryTodosStorage(), scheduler: HeldScheduler(), now: { clock.now })
        store.connect(server)
        await store.refresh()
        let page = TodoPage.view("any")
        await store.loadPage(page)
        await store.loadChildren(of: "11111111-0000-7000-8000-0000000000a1")
        let rows = TodoRows.build(
            result: store.results[page.key], pending: [], todos: store.todos,
            expanded: ["11111111-0000-7000-8000-0000000000a1"], children: store.childIds)
        XCTAssertTrue(
            rows.contains(
                .todo(id: "11111111-0000-7000-8000-0000000000a2", depth: 1, expandable: false, expanded: false)))

        await server.set(network: .down)
        let tick = try XCTUnwrap(store.toggleDone(todoId: "11111111-0000-7000-8000-0000000000a2"))
        await store.drain()
        XCTAssertEqual(store.todos["11111111-0000-7000-8000-0000000000a2"]?.status, .done)
        XCTAssertEqual(store.queue.map(\.changeId), [tick])

        await server.set(network: .up)
        store.retryNow()
        await store.drain()
        let applied = await server.appliedLog
        XCTAssertEqual(applied, [tick])
        let child = await server.todos["11111111-0000-7000-8000-0000000000a2"]
        XCTAssertEqual(child?.status, .done)
    }

    /// A line typed in the add sheet on a page lands as the op the web sends for the same line on
    /// the same page: the parser's reading over the page's defaults.
    func testTheAddSheetSendsTheWebsOpForATypedLine() async throws {
        struct Case: Decodable {
            let name: String
            let inView: PaiJSONValue
        }
        let cases = try TodosWireSamples.decode([Case].self, "web-create-vectors")
        XCTAssertEqual(cases.count, 4)
        for case_ in cases {
            let answer = try TodosWireSamples.decode(TodosParseAnswer.self, case_.name)
            let store = TodosStore(storage: InMemoryTodosStorage(), scheduler: HeldScheduler(), makeId: { "n1" })
            let place = TodoCreatePlace(
                defaults: try JSONDecoder().decode(
                    TodoViewDefaults.self, from: Data(#"{"tags":["errand"],"horizon":"week"}"#.utf8)),
                listId: "LIST", page: "list:LIST")
            store.capture(text: answer.title, place: place, parsed: answer)
            let op = try XCTUnwrap(store.queue.first?.ops.first)
            XCTAssertEqual(PaiJSONValue.object(op.fields), case_.inView, case_.name)
            XCTAssertEqual(store.pendingRows(on: .list("LIST")), ["n1"], "drawn on the page it was added on")
        }
    }

    /// Browse lists the favourites in the person's order with their counts, the other views, the
    /// lists that are not archived with theirs, and the tags by name, folded once views of one's own exist.
    func testBrowseHasTheSidebarsSections() async throws {
        let me = try TodosWireSamples.decode(TodosMeAnswer.self, "me")
        let first = try XCTUnwrap(me.views.filter(\.pinned).min { $0.rank < $1.rank })
        let browse = TodoBrowse.make(me: me, viewCounts: [first.id: 7])
        XCTAssertEqual(browse.favourites.first?.id, first.id)
        XCTAssertEqual(browse.favourites.first?.count, 7)
        XCTAssertEqual(browse.favourites.count + browse.moreViews.count, me.views.count)
        XCTAssertEqual(browse.lists.map(\.id).sorted(), me.lists.filter { !$0.archived }.map(\.id).sorted())
        XCTAssertEqual(TodoBrowse.home(me)?.id, first.id)
    }
}
