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

    /// Who `/me` says the credential is; the captured sample's person when nil.
    private var principal: String?
    func signIn(as principal: String?) { self.principal = principal }

    /// Answers the next applies fail with, in order, before anything is written.
    private var applyFailures: [Error] = []
    func failNextApplies(_ errors: [Error]) { applyFailures = errors }

    /// `/me` waits until `releaseMe()` while held.
    private var meHeld = false
    private var meWaiters: [CheckedContinuation<Void, Never>] = []
    func holdMe() { meHeld = true }
    func releaseMe() {
        meHeld = false
        for waiter in meWaiters { waiter.resume() }
        meWaiters = []
    }

    /// An apply waits, before anything is written, until `releaseApply()` while held.
    private var applyHeld = false
    private var applyWaiters: [CheckedContinuation<Void, Never>] = []
    private var applyArrivals: [CheckedContinuation<Void, Never>] = []
    func holdApply() { applyHeld = true }
    func releaseApply() {
        applyHeld = false
        for waiter in applyWaiters { waiter.resume() }
        applyWaiters = []
    }
    /// Returns once an apply is waiting at the hold.
    func waitForHeldApply() async {
        if !applyWaiters.isEmpty { return }
        await withCheckedContinuation { applyArrivals.append($0) }
    }

    /// Events the feed answers with, as if written on another device.
    private var feed: [TodoEvent] = []
    func publish(_ event: TodoEvent) { feed.append(event) }
    private(set) var meReads = 0
    private(set) var applyCalls = 0
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
        if applyHeld {
            await withCheckedContinuation { continuation in
                applyWaiters.append(continuation)
                for arrival in applyArrivals { arrival.resume() }
                applyArrivals = []
            }
        }
        try reach()
        applyCalls += 1
        if !applyFailures.isEmpty { throw applyFailures.removeFirst() }
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
                row.parentId = op.string("parent")
                row.childrenOpen = 0
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
            case "todo.update":
                guard var row = staged[op.string("todo")!] else {
                    throw try refusal("error-404-not-found", status: 404)
                }
                if let title = op.object("set")?.string("title") { row.title = title }
                row.updatedSeq = seq
                staged[row.id] = row
                touched[row.id] = row
            case "desk.add":
                guard let id = op.string("todo"), staged[id] != nil else {
                    throw try refusal("error-404-not-found", status: 404)
                }
                if !stagedDesk.contains(where: { $0.todoId == id }) {
                    let item = TodoDeskItem(id: UUID().uuidString, kind: .todo, todoId: id, title: nil)
                    var at = stagedDesk.count
                    if case .string("first") = op.fields["position"] { at = 0 }
                    if let after = op.object("position")?.string("after"),
                        let index = stagedDesk.firstIndex(where: { $0.id == after || $0.todoId == after })
                    {
                        at = index + 1
                    }
                    stagedDesk.insert(item, at: at)
                }
            case "todo.body":
                guard var row = staged[op.string("todo")!] else {
                    throw try refusal("error-404-not-found", status: 404)
                }
                if let expected = op.string("if_body_hash"), expected != row.bodyHash {
                    throw try refusal("error-409-conflict", status: 409)
                }
                row.body = op.string("set")
                row.bodyHash = TodoBlobs.sha256Hex(Data((row.body ?? "").utf8))
                row.updatedSeq = seq
                staged[row.id] = row
                touched[row.id] = row
            case "desk.divider":
                stagedDesk.append(
                    TodoDeskItem(id: op.string("id")!, kind: .divider, todoId: nil, title: op.string("title")))
            case "attachment.add":
                guard staged[op.string("todo")!] != nil else { throw try refusal("error-404-not-found", status: 404) }
                guard let blob = op.string("blob"), blobs[blob] != nil else {
                    throw TodosApiError(statusCode: 422, body: .plain("blob", "No such file was uploaded."))
                }
                attached.append((todo: op.string("todo")!, blob: blob, name: op.string("name") ?? ""))
            case "desk.remove":
                stagedDesk.removeAll { $0.todoId == op.string("item") || $0.id == op.string("item") }
            default:
                break
            }
        }
        // What the change replaced, for an undo: the rows as they were before, and the seq each
        // touched row had afterwards, which a later change moves on.
        undoable[change.changeId] = (
            before: touched.keys.map { todos[$0] }, after: touched.mapValues(\.updatedSeq), desk: desk
        )
        todos = staged
        desk = stagedDesk
        appliedLog.append(change.changeId)
        appliedAs[change.changeId] = principal ?? (try? TodosWireSamples.decode(TodosMeAnswer.self, "me").principal)
        let answer = TodosApplyResult(
            change: TodoChange(
                id: change.changeId, seqFirst: seq, seqLast: seq,
                actor: TodoActor(principal: principal ?? "user:sample", kind: .human, label: "Owner"),
                source: source.rawValue,
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

    private var undoable: [String: (before: [Todo?], after: [String: Int], desk: [TodoDeskItem])] = [:]
    private(set) var undone: [String] = []

    /// Puts back what an applied change replaced, as the server's strict undo does: refused with
    /// `undo_conflict` when a row it touched was changed since.
    func todosUndo(changeId: String, _ request: TodosUndoRequest) async throws -> TodosApplyResult {
        try reach()
        guard let record = undoable[changeId] else { throw try refusal("error-404-not-found", status: 404) }
        let moved = record.after.filter { todos[$0.key]?.updatedSeq != $0.value }.map(\.key)
        if !moved.isEmpty {
            let body = try JSONDecoder().decode(
                TodosErrorBody.self,
                from: JSONSerialization.data(withJSONObject: [
                    "error": "undo_conflict", "message": "Changed since.", "fields": moved.map { _ in "status" },
                ]))
            throw TodosApiError(statusCode: 409, body: body)
        }
        seq += 1
        var restored: [Todo] = []
        for (id, _) in record.after {
            if var row = record.before.compactMap({ $0 }).first(where: { $0.id == id }) {
                row.updatedSeq = seq
                todos[id] = row
                restored.append(row)
            } else {
                todos[id] = nil
            }
        }
        desk = record.desk
        undoable[changeId] = nil
        undone.append(changeId)
        return TodosApplyResult(
            change: nil, applied: 1, of: 1, results: [TodoOpResult(index: 0, ok: true, ref: nil, id: nil, error: nil)],
            todos: restored, events: [], replayed: false)
    }

    /// Change ids applied, with the principal whose credential applied them.
    private(set) var appliedAs: [String: String] = [:]

    /// The next `/me` reads fail as with no network.
    private var meFailures = 0
    func failNextMe(_ count: Int = 1) { meFailures = count }

    func todosMe() async throws -> TodosMeAnswer {
        if meHeld { await withCheckedContinuation { meWaiters.append($0) } }
        try reach()
        if meFailures > 0 {
            meFailures -= 1
            throw URLError(.networkConnectionLost)
        }
        meReads += 1
        let sample = try TodosWireSamples.decode(TodosMeAnswer.self, "me")
        guard let principal else { return sample }
        return TodosMeAnswer(
            principal: principal, userId: sample.userId, displayName: "Someone", actorKind: .human,
            lists: sample.lists, prefs: sample.prefs, views: sample.views, tags: sample.tags, seq: sample.seq,
            nudgeDevices: sample.nudgeDevices)
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
        let sample = try TodosWireSamples.decode(TodosParseAnswer.self, "parse-fields")
        if text.hasPrefix("Call the plumber") { return sample }
        if text.hasSuffix("no date") { return try TodosWireSamples.decode(TodosParseAnswer.self, "parse-no-date") }
        // Words the sample does not cover read as a plain title, as the parser reads them.
        let plain: [String: Any] = [
            "title": text, "tokens": [], "issues": [],
            "fields": [
                "tags": [], "horizon": NSNull(), "when": NSNull(), "deadline": NSNull(), "repeat": NSNull(),
                "parent": NSNull(), "list": NSNull(), "desk": false, "nudges": [],
            ],
            "create_op": ["op": "todo.create", "id": UUID().uuidString.lowercased(), "title": text],
        ]
        return try JSONDecoder().decode(TodosParseAnswer.self, from: JSONSerialization.data(withJSONObject: plain))
    }

    func todosEvents(after: Int) async throws -> TodosEventsAnswer {
        try reach()
        let events = feed.filter { $0.seq > after }
        return TodosEventsAnswer(events: events, head: max(seq, events.map(\.seq).max() ?? 0), reset: false)
    }

    /// The next feed position, for an event published by a test.
    func nextSeq() -> Int {
        seq += 1
        return seq
    }

    /// A todo the server holds already, as if made on another device.
    /// A description changed by someone else.
    func overwriteBody(of id: String, _ body: String) throws {
        guard var row = todos[id] else { throw try refusal("error-404-not-found", status: 404) }
        seq += 1
        row.body = body
        row.bodyHash = TodoBlobs.sha256Hex(Data(body.utf8))
        row.updatedSeq = seq
        todos[id] = row
    }

    func seed(id: String, title: String, parent: String? = nil) throws {
        var row = try template()
        number += 1
        seq += 1
        row.id = id
        row.rootId = parent ?? id
        row.parentId = parent
        row.depth = parent == nil ? 0 : 1
        row.number = number
        row.title = title
        row.updatedSeq = seq
        row.childrenOpen = 0
        todos[id] = row
        if let parent, var owner = todos[parent] {
            owner.childrenOpen += 1
            todos[parent] = owner
        }
    }

    /// Every view runs as the open roots, ungrouped, as a fold answer does.
    func todosRunView(id: String, cursor: String?) async throws -> TodosQueryAnswer {
        try reach()
        let roots = todos.values.filter { $0.status == .open && $0.parentId == nil }.sorted { $0.title < $1.title }
        return TodosQueryAnswer(
            todos: roots, groups: [], total: roots.count, nextCursor: nil, seq: seq,
            explain: TodoExplain(normalized: "", defaults: []))
    }

    func todosViewCounts() async throws -> TodosViewCountsAnswer {
        try reach()
        let views = try TodosWireSamples.decode(TodosMeAnswer.self, "me").views
        return TodosViewCountsAnswer(views: views.map { .init(id: $0.id, count: 1) }, seq: seq)
    }

    func todosDetail(ref: String) async throws -> TodosDetailAnswer {
        try reach()
        guard let todo = todos[ref] ?? todos.values.first(where: { $0.ref == ref }) else {
            throw try refusal("error-404-not-found", status: 404)
        }
        let children = todos.values.filter { $0.parentId == ref && $0.status == .open }.sorted { $0.title < $1.title }
        return TodosDetailAnswer(todo: todo, children: children, nudges: [], history: nil)
    }

    /// Every child, done ones too, as the sheet asks.
    func todosSheet(ref: String) async throws -> TodosDetailAnswer {
        try reach()
        guard let todo = todos[ref] else { throw try refusal("error-404-not-found", status: 404) }
        let children = todos.values.filter { $0.parentId == ref }.sorted { $0.title < $1.title }
        return TodosDetailAnswer(todo: todo, children: children, nudges: [], history: [])
    }

    func todosUpcoming(days: Int) async throws -> TodosUpcomingAnswer {
        try reach()
        return TodosUpcomingAnswer(days: [], later: [], someday: [], todos: [:], seq: seq)
    }

    func todosLogbook(cursor: String?) async throws -> TodosLogbookAnswer {
        try reach()
        return TodosLogbookAnswer(days: [], todos: [:], nextCursor: nil)
    }

    private(set) var composed: [TodosComposeRequest] = []
    private var composeAnswer: TodosComposeAnswer?
    private var composeRefuses = false

    /// What the model reads next; nil answers the captured sample.
    func setCompose(_ answer: TodosComposeAnswer?, refuses: Bool = false) {
        composeAnswer = answer
        composeRefuses = refuses
    }

    func todosCompose(_ request: TodosComposeRequest) async throws -> TodosComposeAnswer {
        try reach()
        composed.append(request)
        if composeRefuses {
            // The route's own refusal when no model answered: 503 `unavailable`.
            let body = try JSONDecoder().decode(
                TodosErrorBody.self, from: Data(#"{"error":"unavailable","message":"No model answered."}"#.utf8))
            throw TodosApiError(statusCode: 503, body: body)
        }
        if let composeAnswer { return composeAnswer }
        return try TodosWireSamples.decode(TodosComposeAnswer.self, "compose")
    }

    func todosPeople() async throws -> TodosPeopleAnswer {
        try reach()
        return TodosPeopleAnswer(people: [])
    }

    /// Bytes stored by hash; an `attachment.add` is taken only for a hash stored here, as the
    /// server takes one only from an uploader of it.
    private(set) var blobs: [String: Data] = [:]
    private(set) var attached: [(todo: String, blob: String, name: String)] = []

    func todosPutBlob(sha256: String, data: Data, contentType: String) async throws {
        try reach()
        blobs[sha256] = data
    }

    func todosAttachment(id: String) async throws -> Data {
        try reach()
        return Data()
    }

    private(set) var searched: [TodosSearchRequest] = []

    func todosSearch(_ request: TodosSearchRequest) async throws -> TodosSearchAnswer {
        try reach()
        searched.append(request)
        return TodosSearchAnswer(
            query: .init(corrections: []), top: nil, todos: [], fewer: [],
            counts: .init(open: 0, closed: 0, deleted: 0, capped: false), tags: [], views: [], lists: [], offers: [],
            nextCursor: nil, examples: nil)
    }
}

/// Storage whose queue never reaches the disk, as on a full or purged volume.
final class FailingQueueStorage: TodosStorage, @unchecked Sendable {
    private let memory = InMemoryTodosStorage()
    func loadQueue() -> [TodosQueuedChange] { [] }
    func saveQueue(_ queue: [TodosQueuedChange]) -> Bool { false }
    func loadRefused() -> [TodosRefusedChange] { memory.loadRefused() }
    func saveRefused(_ refused: [TodosRefusedChange]) { memory.saveRefused(refused) }
    func loadCache() -> TodosCache? { memory.loadCache() }
    func saveCache(_ cache: TodosCache?) { memory.saveCache(cache) }
    func saveBlob(_ data: Data, sha256: String) -> Bool { memory.saveBlob(data, sha256: sha256) }
    func loadBlob(sha256: String) -> Data? { memory.loadBlob(sha256: sha256) }
    func removeBlob(sha256: String) { memory.removeBlob(sha256: sha256) }
}
