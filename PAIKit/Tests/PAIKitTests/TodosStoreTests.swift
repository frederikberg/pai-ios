import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A retry that never fires by itself: the tests say when the network is back.
private struct HeldScheduler: DraftScheduler {
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ iso: String) { value = IsoTimestamp.date(from: iso)! }
    var now: Date { lock.withLock { value } }
    func advance(hours: Double) { lock.withLock { value = value.addingTimeInterval(hours * 3600) } }
}

/// The server's rules, as far as the queue meets them: a change id applied once and answered
/// again on a replay, a tick of a todo it does not have refused with 404, a locked list
/// refused with 403, and a network that can be down, lose an answer after applying, or have
/// no sign-in.
private actor FakeTodosServer: TodosBackend {
    enum Network { case up, down, signedOut }

    var network = Network.up
    /// The next apply is written, then its answer is lost on the way back.
    var loseNextAnswer = false
    private(set) var todos: [String: Todo] = [:]
    private(set) var desk: [TodoDeskItem] = []
    /// Change ids in the order they were first applied.
    private(set) var appliedLog: [String] = []
    private(set) var parsed: [String] = []
    private var answers: [String: TodosApplyResult] = [:]
    private var seq = 100
    private var number = 0

    static let lockedList = "locked-list"

    func set(network: Network) { self.network = network }
    func loseTheNextAnswer() { loseNextAnswer = true }

    private func reach() throws {
        switch network {
        case .up: return
        case .down: throw URLError(.notConnectedToInternet)
        case .signedOut: throw PaiError.detail("Not authenticated", statusCode: 401)
        }
    }

    private func template() throws -> Todo {
        try TodosWireSamples.decode(TodosQueryAnswer.self, "query-open").todos.first {
            $0.repeat == nil && $0.parentId == nil
        }!
    }

    private func refusal(_ name: String, status: Int) throws -> TodosApiError {
        TodosApiError(statusCode: status, body: try TodosWireSamples.decode(TodosErrorBody.self, name))
    }

    func todosApply(_ change: TodosChangeRequest, source: TodosSource) async throws -> TodosApplyResult {
        try reach()
        if let answer = answers[change.changeId] {
            return TodosApplyResult(
                change: answer.change, applied: answer.applied, of: answer.of, results: answer.results,
                todos: answer.todos, events: answer.events, replayed: true)
        }
        var touched: [String: Todo] = [:]
        var staged = todos
        var stagedDesk = desk
        for op in change.ops {
            seq += 1
            switch op.name {
            case "todo.create":
                if op.string("list") == Self.lockedList { throw try refusal("error-403-locked", status: 403) }
                var row = try template()
                number += 1
                row.id = op.string("id")!
                row.rootId = row.id
                row.number = number
                row.ref = "T-\(number)"
                row.title = op.string("title")!
                row.tags = op.strings("tags") ?? []
                row.created.source = source.rawValue
                row.status = .open
                row.updatedSeq = seq
                staged[row.id] = row
                touched[row.id] = row
                if op.bool("desk") == true {
                    stagedDesk.append(TodoDeskItem(id: UUID().uuidString, kind: .todo, todoId: row.id, title: nil))
                }
            case "todo.complete", "todo.reopen":
                guard var row = staged[op.string("todo")!] else {
                    throw try refusal("error-404-not-found", status: 404)
                }
                row.status = op.name == "todo.complete" ? .done : .open
                row.updatedSeq = seq
                staged[row.id] = row
                touched[row.id] = row
            case "desk.add":
                guard let id = op.string("todo"), staged[id] != nil else {
                    throw try refusal("error-404-not-found", status: 404)
                }
                if !stagedDesk.contains(where: { $0.todoId == id }) {
                    stagedDesk.append(TodoDeskItem(id: UUID().uuidString, kind: .todo, todoId: id, title: nil))
                }
            case "desk.remove":
                stagedDesk.removeAll { $0.todoId == op.string("item") || $0.id == op.string("item") }
            default:
                break
            }
        }
        todos = staged
        desk = stagedDesk
        appliedLog.append(change.changeId)
        let answer = TodosApplyResult(
            change: TodoChange(
                id: change.changeId, seqFirst: seq, seqLast: seq,
                actor: TodoActor(principal: "user:fake", kind: .human, label: "Owner"), source: source.rawValue,
                sessionId: nil, summary: "", opCount: change.ops.count, undoOf: nil, undoneBy: nil,
                createdAt: "2026-11-26T10:00:00+00:00", events: nil),
            applied: change.ops.count, of: change.ops.count,
            results: change.ops.indices.map { TodoOpResult(index: $0, ok: true, ref: nil, id: nil, error: nil) },
            todos: Array(touched.values), events: [], replayed: false)
        answers[change.changeId] = answer
        if loseNextAnswer {
            loseNextAnswer = false
            throw URLError(.networkConnectionLost)
        }
        return answer
    }

    func todosMe() async throws -> TodosMeAnswer {
        try reach()
        return try TodosWireSamples.decode(TodosMeAnswer.self, "me")
    }

    func todosToday() async throws -> TodosTodayAnswer {
        try reach()
        let onDesk = desk.compactMap(\.todoId)
        return TodosTodayAnswer(
            desk: desk, todos: todos.filter { onDesk.contains($0.key) }, due: [], seq: seq, day: "2026-11-26")
    }

    func todosQuery(_ request: TodosQueryRequest) async throws -> TodosQueryAnswer {
        try reach()
        let open = todos.values.filter { $0.status == .open }
        return TodosQueryAnswer(
            todos: Array(open), groups: [], total: open.count, nextCursor: nil, seq: seq,
            explain: TodoExplain(normalized: request.q, defaults: []))
    }

    func todosParse(text: String, list: String?, source: TodosSource) async throws -> TodosParseAnswer {
        try reach()
        parsed.append(text)
        return try TodosWireSamples.decode(TodosParseAnswer.self, "parse-fields")
    }

    func todosEvents(after: Int) async throws -> TodosEventsAnswer {
        try reach()
        return TodosEventsAnswer(events: [], head: seq, reset: false)
    }

    /// A todo the server holds already, as if made on another device.
    func seed(id: String, title: String) throws {
        var row = try template()
        number += 1
        seq += 1
        row.id = id
        row.rootId = id
        row.number = number
        row.title = title
        row.updatedSeq = seq
        todos[id] = row
    }
}

@MainActor
final class TodosStoreTests: XCTestCase {

    private func makeStore(
        _ storage: any TodosStorage = InMemoryTodosStorage(), clock: Clock = Clock("2026-11-26T10:00:00+01:00")
    ) -> TodosStore {
        TodosStore(storage: storage, scheduler: HeldScheduler(), now: { clock.now })
    }

    private func temporaryStorage() throws -> FileTodosStorage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("todos-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return FileTodosStorage(
            rootURL: root.appendingPathComponent("outbox"), cacheDirectory: root.appendingPathComponent("cache"))
    }

    /// A cold start without a network shows what the last read held: the lists, the open todos,
    /// the desk, and a change still waiting drawn over them.
    func testAColdStartWithoutANetworkShowsTheLastAnswers() async throws {
        let storage = try temporaryStorage()
        let server = FakeTodosServer()
        try await server.seed(id: "11111111-0000-7000-8000-000000000001", title: "Return the drill")
        try await server.seed(id: "11111111-0000-7000-8000-000000000002", title: "Book the train")
        let first = makeStore(storage)
        first.connect(server)
        let onDesk = first.setOnDesk(todoId: "11111111-0000-7000-8000-000000000002", true)
        _ = await first.settled(onDesk, timeout: 60)
        await first.refresh()
        await server.set(network: .down)
        first.toggleDone(todoId: "11111111-0000-7000-8000-000000000001")
        await first.drain()
        XCTAssertEqual(first.queue.count, 1)

        let relaunched = makeStore(
            FileTodosStorage(rootURL: storage.rootURL, cacheDirectory: storage.cacheURL.deletingLastPathComponent()))

        XCTAssertFalse(relaunched.lists.isEmpty)
        XCTAssertEqual(relaunched.lists.map(\.id), first.lists.map(\.id))
        XCTAssertEqual(relaunched.todos["11111111-0000-7000-8000-000000000002"]?.title, "Book the train")
        XCTAssertEqual(
            relaunched.deskItems.compactMap(\.todoId), ["11111111-0000-7000-8000-000000000002"])
        XCTAssertEqual(relaunched.todos["11111111-0000-7000-8000-000000000001"]?.status, .done)
        XCTAssertEqual(relaunched.queue.count, 1)
    }

    /// Made offline, an add and a tick of what it added go out once each, in order, when the
    /// network returns, even when the first answer is lost after the server applied it.
    func testAQueuedAddAndTickGoOutOnceInOrder() async throws {
        let server = FakeTodosServer()
        await server.set(network: .down)
        let store = makeStore()
        store.connect(server)
        let id = TodosStore.uuidv7()
        let add = store.submit([.create(id: id, title: "Buy light bulbs")])
        let tick = store.submit([.complete(todo: id)])
        await store.drain()
        XCTAssertTrue(store.offline)
        XCTAssertEqual(store.queue.map(\.changeId), [add, tick])
        XCTAssertEqual(store.todos[id]?.status, .done, "drawn before the server answered")

        await server.set(network: .up)
        await server.loseTheNextAnswer()
        store.retryNow()
        await store.drain()
        XCTAssertEqual(store.queue.map(\.changeId), [add, tick], "a lost answer keeps the change queued")

        store.retryNow()
        await store.drain()

        let appliedLog = await server.appliedLog
        XCTAssertEqual(appliedLog, [add, tick])
        let created = await server.todos[id]
        XCTAssertEqual(created?.status, .done)
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertFalse(store.offline)
        XCTAssertEqual(store.todos[id]?.number, created?.number)
        let outcome = await store.settled(tick, timeout: 60)
        guard case .applied = outcome else { return XCTFail("\(outcome)") }
    }

    /// An expired sign-in is neither a dropped connection nor a refusal: the whole queue stays,
    /// across a relaunch, and goes out once there is a sign-in again.
    func testAnExpiredSignInKeepsTheQueue() async throws {
        let storage = InMemoryTodosStorage()
        let server = FakeTodosServer()
        await server.set(network: .signedOut)
        let store = makeStore(storage)
        store.connect(server)
        let first = store.submit([.create(id: TodosStore.uuidv7(), title: "Call the bank")])
        let second = store.submit([.create(id: TodosStore.uuidv7(), title: "Pay the rent")])
        await store.drain()
        XCTAssertTrue(store.signedOut)
        XCTAssertFalse(store.offline)
        XCTAssertEqual(store.queue.map(\.changeId), [first, second])
        XCTAssertTrue(store.refused.isEmpty)
        store.disconnect()

        let relaunched = makeStore(storage)
        XCTAssertEqual(relaunched.queue.map(\.changeId), [first, second])
        await server.set(network: .up)
        relaunched.connect(server)
        await relaunched.drain()

        let appliedLog = await server.appliedLog
        XCTAssertEqual(appliedLog, [first, second])
        XCTAssertTrue(relaunched.queue.isEmpty)
    }

    /// Words captured offline wait for the server's parser, and the todo they become is the one
    /// the queue drew. A capture that waited past the person's day boundary is not read against
    /// the wrong day: its words become the title as they are.
    func testACaptureIsReadWhenItGoesOutAndNeverAgainstAnotherDay() async throws {
        let clock = Clock("2026-11-26T10:00:00+01:00")
        let server = FakeTodosServer()
        let store = makeStore(clock: clock)
        store.connect(server)
        await store.refresh()
        await server.set(network: .down)

        let spoken = "Call the plumber tomorrow 17:00 #home p1"
        let today = store.capture(text: spoken, source: .shortcut)
        await store.drain()
        let todayId = try XCTUnwrap(store.queue.first?.capture?.todoId)
        XCTAssertEqual(store.todos[todayId]?.title, spoken)

        await server.set(network: .up)
        store.retryNow()
        await store.drain()
        _ = await store.settled(today, timeout: 60)
        let parsed = await server.parsed
        XCTAssertEqual(parsed, [spoken])
        let made = await server.todos[todayId]
        XCTAssertEqual(made?.tags, ["home"])
        XCTAssertEqual(made?.title, "Call the plumber")
        XCTAssertEqual(made?.created.source, "shortcut")

        await server.set(network: .down)
        let late = store.capture(text: "Water the plants tomorrow")
        await store.drain()
        let lateId = try XCTUnwrap(store.queue.first?.capture?.todoId)
        clock.advance(hours: 20)
        await server.set(network: .up)
        store.retryNow()
        await store.drain()
        _ = await store.settled(late, timeout: 60)
        let parsedAfter = await server.parsed
        XCTAssertEqual(parsedAfter, [spoken])
        let plain = await server.todos[lateId]
        XCTAssertEqual(plain?.title, "Water the plants tomorrow")
    }

    /// A refused change leaves the queue with its words kept and the reason told; what was queued
    /// behind it still goes out.
    func testARefusalDropsOnlyThatChangeAndKeepsItsWords() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        var told: [TodosRefusal] = []
        store.onRefusal = { told.append($0) }
        await server.set(network: .down)
        store.connect(server)
        let refusedChange = store.submit([
            .create(id: TodosStore.uuidv7(), title: "Oat milk", list: FakeTodosServer.lockedList)
        ])
        let next = store.submit([.create(id: TodosStore.uuidv7(), title: "Rye bread")])
        await store.drain()
        await server.set(network: .up)
        store.retryNow()
        await store.drain()

        let appliedLog = await server.appliedLog
        XCTAssertEqual(appliedLog, [next])
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.refused.map(\.text), ["Oat milk"])
        XCTAssertEqual(told.map(\.code), ["locked"])
        let outcome = await store.settled(refusedChange, timeout: 60)
        guard case .refused(let refusal) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(refusal.code, "locked")
    }

    /// A change goes out only as the person who queued it.
    func testAChangeWaitsForThePersonWhoQueuedIt() async throws {
        let storage = InMemoryTodosStorage()
        storage.saveQueue([
            TodosQueuedChange(
                changeId: "0190a000-0000-7000-8000-000000000001", summary: nil,
                ops: [.create(id: "0190a000-0000-7000-8000-0000000000aa", title: "Someone else's")],
                source: "ios", principal: "user:somebody-else", queuedAt: "2026-11-26T09:00:00+00:00")
        ])
        let server = FakeTodosServer()
        let store = makeStore(storage)
        store.connect(server)
        await store.refresh()

        let appliedLog = await server.appliedLog
        XCTAssertTrue(appliedLog.isEmpty)
        XCTAssertEqual(store.queue.count, 1)
    }
}

final class TodosStorageTests: XCTestCase {

    /// A queue written by an earlier build reads back, and every op goes out exactly as it was
    /// queued; an entry this build cannot read is set aside, never dropped or overwritten.
    func testTheOutboxRecordReadsBackAndSetsAsideWhatItCannotRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("todos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let record = try TodosWireSamples.data("outbox-v1")
        try record.write(to: outbox.appendingPathComponent("outbox.json"))

        let storage = FileTodosStorage(rootURL: outbox, cacheDirectory: root.appendingPathComponent("cache"))
        let queue = storage.loadQueue()

        let written =
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: record) as? [String: Any])["changes"] as? [[String: Any]]
        XCTAssertEqual(queue.count, (written?.count ?? 0) - 1)
        XCTAssertEqual(queue.first?.capture?.text, "Ask about the parcel")
        let sent = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TodosChangeRequest(changeId: queue[1].changeId, summary: nil, ops: queue[1].ops))
        )
        let original = written?[1]["ops"] as? [[String: Any]]
        XCTAssertEqual(
            ((sent as? [String: Any])?["ops"] as? [[String: Any]])?.map { NSDictionary(dictionary: $0) },
            original?.map { NSDictionary(dictionary: $0) })

        let unreadable = try FileManager.default.contentsOfDirectory(
            atPath: outbox.appendingPathComponent("unreadable").path)
        XCTAssertEqual(unreadable.count, 1)
        XCTAssertEqual(storage.loadQueue().count, queue.count, "the set-aside entry is not read again")
    }
}
