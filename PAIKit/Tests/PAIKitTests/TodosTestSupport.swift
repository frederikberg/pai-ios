import Foundation

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A retry that never fires by itself: the tests say when the network is back.
struct HeldScheduler: DraftScheduler {
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}

final class TodosTestClock: @unchecked Sendable {
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
actor FakeTodosServer: TodosBackend {
    enum Network { case up, down, signedOut }

    var network = Network.up
    /// The next apply is written, then its answer is lost on the way back.
    var loseNextAnswer = false
    private(set) var todos: [String: Todo] = [:]
    private(set) var desk: [TodoDeskItem] = []
    /// Change ids in the order they were first applied.
    private(set) var appliedLog: [String] = []
    private(set) var parsed: [String] = []
    /// Every `todo.create` applied, by the todo's id, as it was sent.
    private(set) var createdOps: [String: TodoOp] = [:]
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
                createdOps[row.id] = op
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
