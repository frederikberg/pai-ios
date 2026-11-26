import Foundation
import XCTest

@testable import PAIKit

/// The engine against a real Todos server: a rig stack's persona address in `TODOS_RIG_URL`
/// (`bun e2e/todos/stack.ts` in pai-cloud prints one per persona; each signs its requests in by
/// itself). Skipped without it, so the free checks never need a server.
@MainActor
final class TodosRigTests: XCTestCase {

    /// Capture, tick, untick and the desk through the real client, then read back through the
    /// server's own query and through a relaunch from the cache.
    func testTheEngineAgreesWithARealServer() async throws {
        guard let url = ProcessInfo.processInfo.environment["TODOS_RIG_URL"], !url.isEmpty else {
            throw XCTSkip("TODOS_RIG_URL is not set")
        }
        let client = PaiApiClient(requestFactory: try PaiRequestFactory(baseURL: url, deviceName: "rig") { nil })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("todos-rig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileTodosStorage(
            rootURL: root.appendingPathComponent("outbox"), cacheDirectory: root.appendingPathComponent("cache"))
        let store = TodosStore(storage: storage)
        store.connect(client)
        await store.refresh()
        XCTAssertNotNil(store.me, "the rig answered /me")

        let word = "rigcheck\(Int.random(in: 1000...9999))"
        let added = store.capture(text: "Post the \(word) letter tomorrow #errands *", source: .shortcut)
        guard case .applied(let result?) = await store.settled(added, timeout: 30) else {
            return XCTFail("the capture was not applied")
        }
        let todo = try XCTUnwrap(result.todos.first)
        XCTAssertEqual(todo.title, "Post the \(word) letter")
        XCTAssertEqual(todo.tags, ["errands"])
        XCTAssertNotNil(todo.when)
        XCTAssertEqual(todo.created.source, "shortcut")
        await store.drain()
        XCTAssertTrue(store.deskItems.contains { $0.todoId == todo.id }, "the parser's * put it on the desk")

        let tick = try XCTUnwrap(store.toggleDone(todoId: todo.id))
        guard case .applied = await store.settled(tick, timeout: 30) else { return XCTFail("tick") }
        XCTAssertEqual(store.todos[todo.id]?.status, .done)
        let untick = try XCTUnwrap(store.toggleDone(todoId: todo.id))
        guard case .applied = await store.settled(untick, timeout: 30) else { return XCTFail("untick") }
        let off = store.setOnDesk(todoId: todo.id, false)
        guard case .applied = await store.settled(off, timeout: 30) else { return XCTFail("desk remove") }
        await store.drain()
        XCTAssertFalse(store.deskItems.contains { $0.todoId == todo.id })

        // `is:any`: a todo meant for tomorrow is asleep, which a query leaves out by default.
        let found = try await client.todosQuery(
            TodosQueryRequest(q: "\(word) is:any", scope: nil, group: "none", tree: "flat"))
        XCTAssertEqual(found.todos.map(\.id), [todo.id])
        XCTAssertEqual(found.todos.first?.status, .open)
        XCTAssertEqual(found.todos.first?.onDesk, false)

        // The share sheet's path: words through the parser, a link attached, multi-line text kept.
        let shared = await store.captureAndWait(
            text: "Read the \(word) recipe #errands\nfrom the bus", links: [.url("https://example.org/\(word)")],
            source: .share, timeout: 30)
        guard case .applied(let sharedResult?) = shared.settlement else { return XCTFail("share capture") }
        let sharedTodo = try XCTUnwrap(sharedResult.todos.first)
        XCTAssertEqual(shared.title, "Read the \(word) recipe")
        XCTAssertEqual(sharedTodo.links.map(\.target), ["https://example.org/\(word)"])
        XCTAssertEqual(sharedTodo.bodyPreview, "from the bus")
        XCTAssertEqual(sharedTodo.created.source, "share")

        await store.refresh()
        let relaunched = TodosStore(storage: storage)
        XCTAssertEqual(relaunched.todos[todo.id]?.title, "Post the \(word) letter")
        XCTAssertTrue(relaunched.queue.isEmpty)
    }
}
