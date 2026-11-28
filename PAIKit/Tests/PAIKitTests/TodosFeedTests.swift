import XCTest

@testable import PAIKit

/// Following the feed while the app is in front.
@MainActor
final class TodosFeedTests: XCTestCase {

    private func makeStore() -> TodosStore {
        let clock = TodosTestClock("2026-11-26T10:00:00+01:00")
        return TodosStore(storage: InMemoryTodosStorage(), scheduler: HeldScheduler(), now: { clock.now })
    }

    /// A todo made on another device is on the phone without anything asking for it.
    func testAChangeMadeElsewhereArrivesWhileFollowing() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()
        store.follow()
        defer { store.unfollow() }

        let id = "11111111-0000-7000-8000-0000000000ef"
        try await server.seed(id: id, title: "Made on the laptop")
        let seq = await server.nextSeq()
        await server.publish(
            TodoEvent(
                seq: seq, changeId: "0190a000-0000-7000-8000-0000000000cd", entity: "todo", entityId: id, todoId: id,
                listId: nil, op: "create", before: nil, after: nil))

        let deadline = Date().addingTimeInterval(10)
        while store.todos[id] == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.todos[id]?.title, "Made on the laptop")
    }

    /// One change made elsewhere is read by the todo it names; the whole open set is not asked
    /// for again.
    func testOneChangeElsewhereDoesNotReadEveryOpenTodoAgain() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()
        let asksBefore = await server.queryAsks
        XCTAssertGreaterThan(asksBefore, 0)

        let id = "11111111-0000-7000-8000-0000000000ee"
        try await server.seed(id: id, title: "Ticked on the laptop")
        let seq = await server.nextSeq()
        await server.publish(
            TodoEvent(
                seq: seq, changeId: "0190a000-0000-7000-8000-0000000000ce", entity: "todo", entityId: id, todoId: id,
                listId: nil, op: "create", before: nil, after: nil))
        await store.catchUp()

        XCTAssertEqual(store.todos[id]?.title, "Ticked on the laptop")
        let asksAfter = await server.queryAsks
        XCTAssertEqual(asksAfter, asksBefore)
    }

    /// A server that answers the feed at once with nothing is not asked again in a loop.
    func testAServerThatDoesNotHoldTheAskIsNotAskedInALoop() async throws {
        let server = FakeTodosServer()
        await server.answerFeedAsksAtOnce()
        let store = makeStore()
        store.connect(server)
        await store.refresh()
        store.follow()
        defer { store.unfollow() }

        let deadline = Date().addingTimeInterval(10)
        while await server.feedAsks == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let asks = await server.feedAsks
        XCTAssertEqual(asks, 1)
    }
}
