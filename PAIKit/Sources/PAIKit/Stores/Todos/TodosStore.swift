import Foundation
import Observation

/// How a submitted change ended, for whoever waits on it (`TodosStore.settled`).
public enum TodosSettlement: Equatable, Sendable {
    /// The server applied it. Nil when the answer arrived but could not be read.
    case applied(TodosApplyResult?)
    case refused(TodosRefusal)
    /// Still queued when the wait ended: no connection, or no sign-in. It goes out by itself.
    case waiting
}

/// The Todos engine: what the server last said (cached on disk, so a cold start without a network
/// shows the open todos, the lists and the desk), the queue of changes not yet applied, and the
/// rules of the web's outbox (`store/outbox.ts`) for sending them.
///
/// Every write is a change: a client-made id and typed ops, drawn at once (the queue overlays the
/// cached todos and the desk), persisted, and sent in order under the same `change_id`, so a
/// resend after a lost answer is a replay rather than a second write. A dropped connection or a
/// 408/429/502/503/504 keeps the change queued; an expired sign-in keeps the whole queue; any other
/// answer is a verdict, which drops the change and says why. A capture's words wait for the
/// server's parser while there is no connection.
///
/// The store belongs to the phone, not to a sign-in: a capture made while signed out waits for
/// the next one. Each change remembers who queued it and goes out only as that person. The
/// initializer only reads the disk; network work starts from `connect` and the calls after it.
@Observable
@MainActor
public final class TodosStore {

    public private(set) var me: TodosMeAnswer?
    /// What the server last said about each todo.
    public private(set) var base: [String: Todo]
    /// `base` with the queue's ops applied: what every screen reads.
    public private(set) var todos: [String: Todo] = [:]
    /// The desk in its hand order, with queued desk ops applied.
    public private(set) var deskItems: [TodoDeskItem] = []
    /// The todos due today that are not on the desk, in the server's order.
    public private(set) var dueIds: [String]
    /// The person's day, as the server last counted it.
    public private(set) var day: String?
    public private(set) var queue: [TodosQueuedChange]
    /// Changes the server refused that carried words someone typed or spoke.
    public private(set) var refused: [TodosRefusedChange]
    /// A send is failing for want of a network: the connection is the problem, not the change.
    public private(set) var offline = false
    /// The server said "signed out": the queue waits for a sign-in, which is not a dropped
    /// connection.
    public private(set) var signedOut = false
    /// Ids of changes this phone applied, newest last.
    public private(set) var appliedIds: [String] = []

    /// Told the reason when the server refuses a change.
    public var onRefusal: (@MainActor (TodosRefusal) -> Void)?

    @ObservationIgnored private var serverDesk: [TodoDeskItem]
    /// Applied desk changes, drawn until a `/today` read at or after their last event replaces
    /// them, so a todo put on the desk does not leave it for the moment between the answer and the
    /// next read.
    @ObservationIgnored private var settling: [(change: TodosQueuedChange, seq: Int)] = []
    /// The feed position to catch up from.
    @ObservationIgnored private var cursor: Int
    @ObservationIgnored private var outcomes: [String: TodosSettlement] = [:]
    @ObservationIgnored private var outcomeOrder: [String] = []
    @ObservationIgnored private var waiters:
        [UUID: (changeId: String, continuation: CheckedContinuation<TodosSettlement, Never>)] = [:]

    @ObservationIgnored private var backend: (any TodosBackend)?
    private let storage: any TodosStorage
    private let scheduler: any DraftScheduler
    private let now: @Sendable () -> Date
    private let makeId: @Sendable () -> String

    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// Resend delays after a dropped connection; the last one repeats.
    public static let retryDelaysSeconds: [TimeInterval] = [1, 2, 5, 15, 30]
    /// How often a queue held back by an expired sign-in tries again.
    public static let signedOutRetrySeconds: TimeInterval = 30
    static let rememberedOutcomes = 30
    static let undoDepth = 50
    static let refusedKept = 50
    /// One query page; the server's ceiling.
    static let openPageSize = 1000
    /// Every open todo, asleep and quiet ones too: `is:any` speaks about the status, the
    /// awake and the quiet-tag axes, so the query's implicit defaults stay out; `is:open` then
    /// narrows the status.
    static let openTodosQuery = "is:open is:any"

    public init(
        storage: any TodosStorage,
        scheduler: any DraftScheduler = RealDraftScheduler(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeId: @escaping @Sendable () -> String = { TodosStore.uuidv7() }
    ) {
        self.storage = storage
        self.scheduler = scheduler
        self.now = now
        self.makeId = makeId
        let cache = storage.loadCache()
        me = cache?.me
        base = cache?.todos ?? [:]
        serverDesk = cache?.today?.desk ?? []
        dueIds = cache?.today?.due.map(\.id) ?? []
        day = cache?.today?.day
        lastToday = cache?.today
        cursor = max(cache?.me?.seq ?? 0, cache?.today?.seq ?? 0)
        queue = storage.loadQueue()
        refused = storage.loadRefused()
        recompute()
    }

    // MARK: - Connection

    /// Attach the server and send what waits. The store keeps everything it holds across a
    /// `disconnect`; this only says where to send it.
    public func connect(_ backend: any TodosBackend) {
        self.backend = backend
        signedOut = false
        Task { await drain() }
    }

    /// The sign-in ended: nothing is sent until the next `connect`, and nothing queued is lost.
    public func disconnect() {
        backend = nil
        retryTask?.cancel()
        retryTask = nil
    }

    /// Forget what the server said, for a deliberate sign-out: the next person must not see this
    /// one's todos. The queue stays; each change goes out only as the person who made it.
    public func forgetCache() {
        me = nil
        base = [:]
        serverDesk = []
        dueIds = []
        day = nil
        settling = []
        lastToday = nil
        cursor = 0
        storage.saveCache(nil)
        recompute()
    }

    // MARK: - Writing

    /// Queue a change and start sending it. Returns its id.
    @discardableResult
    public func submit(_ ops: [TodoOp], summary: String? = nil, source: TodosSource = .ios) -> String {
        enqueue(
            TodosQueuedChange(
                changeId: makeId(), summary: summary, ops: ops, source: source.rawValue, principal: me?.principal,
                queuedAt: IsoTimestamp.utcString(from: now())))
    }

    /// Queue a todo from words typed or spoken, read by the server's capture parser (dates, tags,
    /// `/List`, `*` for the desk). `parsed` is the parser's answer for exactly `text` when one is
    /// at hand (the add sheet asks while typing); otherwise the words are read when the change goes
    /// out. Returns the change's id.
    @discardableResult
    public func capture(
        text: String, list: String? = nil, links: [TodoLinkSpec] = [], parsed: TodosParseAnswer? = nil,
        source: TodosSource = .ios
    ) -> String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let capture = TodosCapture(text: words, todoId: makeId(), list: list, links: links, day: currentDay())
        let ops = parsed.map { [Self.createOp(capture, from: $0)] } ?? []
        return enqueue(
            TodosQueuedChange(
                changeId: makeId(), summary: nil, ops: ops, capture: capture, source: source.rawValue,
                principal: me?.principal, queuedAt: IsoTimestamp.utcString(from: now())))
    }

    /// Tick an open todo, or reopen a closed one.
    @discardableResult
    public func toggleDone(todoId: String) -> String? {
        guard let todo = todos[todoId] else { return nil }
        return submit([todo.status == .open ? .complete(todo: todoId) : .reopen(todo: todoId)])
    }

    /// Put a todo on the desk, or take it off.
    @discardableResult
    public func setOnDesk(todoId: String, _ onDesk: Bool) -> String {
        submit([onDesk ? .deskAdd(todo: todoId) : .deskRemove(item: todoId)])
    }

    /// Forget a refused change's words once the person has kept or let go of them.
    public func discardRefused(changeId: String) {
        refused.removeAll { $0.changeId == changeId }
        storage.saveRefused(refused)
    }

    private func enqueue(_ change: TodosQueuedChange) -> String {
        queue.append(change)
        storage.saveQueue(queue)
        recompute()
        Task { await drain() }
        return change.changeId
    }

    /// Skip whatever backoff is being waited out and send now: the network is back.
    public func retryNow() {
        failures = 0
        retryTask?.cancel()
        retryTask = nil
        Task { await drain() }
    }

    /// Resolves when a submitted change has left the queue, or after `timeout` seconds with
    /// `.waiting`. For a caller that reports the outcome (an App Intent, a sheet that closes once
    /// its change took).
    public func settled(_ changeId: String, timeout: TimeInterval) async -> TodosSettlement {
        if let outcome = outcomes[changeId] { return outcome }
        guard queue.contains(where: { $0.changeId == changeId }) else { return .waiting }
        let token = UUID()
        let timer = Task { [weak self, scheduler] in
            do { try await scheduler.sleep(seconds: timeout) } catch { return }
            self?.finishWaiter(token, .waiting)
        }
        let outcome = await withCheckedContinuation { continuation in
            waiters[token] = (changeId, continuation)
        }
        timer.cancel()
        return outcome
    }

    private func finishWaiter(_ token: UUID, _ outcome: TodosSettlement) {
        waiters.removeValue(forKey: token)?.continuation.resume(returning: outcome)
    }

    private func settle(_ changeId: String, _ outcome: TodosSettlement) {
        outcomes[changeId] = outcome
        outcomeOrder.append(changeId)
        while outcomeOrder.count > Self.rememberedOutcomes { outcomes.removeValue(forKey: outcomeOrder.removeFirst()) }
        for (token, waiter) in waiters where waiter.changeId == changeId { finishWaiter(token, outcome) }
    }

    // MARK: - Sending

    /// Send the queue in order, stopping at the first change that has to wait. A call while a
    /// send is running waits for that one, which also sends whatever was queued meanwhile.
    public func drain() async {
        if let running = drainTask {
            await running.value
            return
        }
        guard backend != nil else { return }
        let task = Task { await sendQueue() }
        drainTask = task
        await task.value
        if drainTask == task { drainTask = nil }
    }

    private func sendQueue() async {
        retryTask?.cancel()
        retryTask = nil
        var acceptedDesk = false
        var acceptedReference = false
        while let backend, let index = nextSendable() {
            var head = queue[index]
            if head.ops.isEmpty, let capture = head.capture {
                guard let op = await readCapture(capture, source: head.source, backend: backend) else { return }
                head.ops = [op]
                replace(head)
            }
            let result: TodosApplyResult
            do {
                result = try await backend.todosApply(
                    TodosChangeRequest(changeId: head.changeId, summary: head.summary, ops: head.ops),
                    source: TodosSource(rawValue: head.source) ?? .ios)
            } catch is TodosUnreadableAnswer {
                // A success the client cannot read: the change is applied all the same, and a
                // resend would only replay the same answer.
                accept(head, nil)
                acceptedDesk = true
                continue
            } catch {
                switch TodosFailure.of(error) {
                case .retry:
                    waitForNetwork()
                    return
                case .signedOut:
                    waitForSignIn()
                    return
                case .refused(let refusal):
                    drop(head, refusal, current: (error as? TodosApiError)?.body.current)
                    continue
                }
            }
            failures = 0
            offline = false
            signedOut = false
            accept(head, result)
            acceptedDesk = acceptedDesk || head.ops.contains(where: Self.touchesDesk)
            acceptedReference = acceptedReference || head.ops.contains(where: Self.touchesReference)
        }
        if acceptedReference { await refreshMe() }
        if acceptedDesk { await refreshToday() }
        // Queued while the reads above were on their way.
        if backend != nil, nextSendable() != nil, retryTask == nil { await sendQueue() }
    }

    /// The first change that may go out as whoever is signed in now. A change queued by someone
    /// else waits for them; one queued before anyone was known goes out as the next person.
    private func nextSendable() -> Int? {
        queue.firstIndex { $0.principal == nil || $0.principal == me?.principal }
    }

    /// The capture's `todo.create`, read by the parser when it is still the day it was spoken on;
    /// its words as the title when not, or when the parser refuses. Nil when the parser could not
    /// be reached: the change waits.
    private func readCapture(_ capture: TodosCapture, source: String, backend: any TodosBackend) async -> TodoOp? {
        guard let spokenOn = capture.day, spokenOn == currentDay() else { return Self.plainCreateOp(capture) }
        do {
            let answer = try await backend.todosParse(
                text: capture.text, list: capture.list, source: TodosSource(rawValue: source) ?? .ios)
            return Self.createOp(capture, from: answer)
        } catch {
            switch TodosFailure.of(error) {
            case .retry:
                waitForNetwork()
                return nil
            case .signedOut:
                waitForSignIn()
                return nil
            case .refused:
                return Self.plainCreateOp(capture)
            }
        }
    }

    /// The parser's `todo.create` for a capture: its fields as the server read them, the
    /// capture's own id, the capture's list when the words named none, and its links. A line the
    /// parser read entirely as fields keeps the words as its title.
    static func createOp(_ capture: TodosCapture, from answer: TodosParseAnswer) -> TodoOp {
        var op = answer.createOp.withoutEmptyFields().setting("op", .string("todo.create"))
            .setting("id", .string(capture.todoId))
        if answer.title.trimmingCharacters(in: .whitespaces).isEmpty { op = op.setting("title", .string(capture.text)) }
        if op.string("list") == nil, let list = capture.list { op = op.setting("list", .string(list)) }
        op = op.setting("created_at", .null).withoutEmptyFields()
        return capture.links.isEmpty ? op : op.setting("links", .array(capture.links.map(\.json)))
    }

    static func plainCreateOp(_ capture: TodosCapture) -> TodoOp {
        .create(id: capture.todoId, title: capture.text, list: capture.list, links: capture.links)
    }

    private func waitForNetwork() {
        offline = true
        let delays = Self.retryDelaysSeconds
        let delay = delays[min(failures, delays.count - 1)]
        failures += 1
        scheduleRetry(after: delay)
    }

    private func waitForSignIn() {
        signedOut = true
        offline = false
        scheduleRetry(after: Self.signedOutRetrySeconds)
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { [weak self, scheduler] in
            do { try await scheduler.sleep(seconds: seconds) } catch { return }
            // Cleared before sending, so `drain` and `retryNow` only ever cancel a task that is
            // still asleep, never one whose requests are in flight.
            self?.retryTask = nil
            await self?.drain()
        }
    }

    /// The server answered. Recorded before the change leaves the queue, so whoever waits on it
    /// finds the verdict the moment it is gone.
    private func accept(_ head: TodosQueuedChange, _ result: TodosApplyResult?) {
        if let result {
            merge(result.todos)
            if result.change != nil {
                appliedIds.append(head.changeId)
                if appliedIds.count > Self.undoDepth { appliedIds.removeFirst(appliedIds.count - Self.undoDepth) }
            }
            if head.ops.contains(where: Self.touchesDesk) {
                settling.append((head, result.change?.seqLast ?? Int.max))
            }
        }
        remove(head)
        settle(head.changeId, .applied(result))
        let failed = result?.results.filter { !$0.ok } ?? []
        if let result, !failed.isEmpty {
            onRefusal?(
                TodosRefusal(code: nil, message: "\(failed.count) of \(result.of) changes were not applied."))
        }
        storage.saveCache(cacheSnapshot())
    }

    /// The server refused the whole change: it leaves the queue, and with it its drawing.
    private func drop(_ head: TodosQueuedChange, _ refusal: TodosRefusal, current: Todo?) {
        if let current { merge([current]) }
        if let words = Self.wordsOf(head) {
            refused.append(
                TodosRefusedChange(
                    changeId: head.changeId, text: words, reason: refusal.message,
                    refusedAt: IsoTimestamp.utcString(from: now())))
            if refused.count > Self.refusedKept { refused.removeFirst(refused.count - Self.refusedKept) }
            storage.saveRefused(refused)
        }
        remove(head)
        settle(head.changeId, .refused(refusal))
        onRefusal?(refusal)
    }

    /// What someone typed or spoke into a change: the captured words, else the titles it creates.
    static func wordsOf(_ change: TodosQueuedChange) -> String? {
        if let capture = change.capture { return capture.text }
        let titles = change.ops.filter { $0.name == "todo.create" }.compactMap { $0.string("title") }
        return titles.isEmpty ? nil : titles.joined(separator: "\n")
    }

    private func replace(_ change: TodosQueuedChange) {
        guard let index = queue.firstIndex(where: { $0.changeId == change.changeId }) else { return }
        queue[index] = change
        storage.saveQueue(queue)
        recompute()
    }

    private func remove(_ change: TodosQueuedChange) {
        queue.removeAll { $0.changeId == change.changeId }
        storage.saveQueue(queue)
        recompute()
    }

    static func touchesDesk(_ op: TodoOp) -> Bool {
        op.name.hasPrefix("desk.") || (op.name == "todo.create" && op.bool("desk") == true)
    }

    /// Ops that change what `/me` carries: lists, members, tags, views, preferences.
    static func touchesReference(_ op: TodoOp) -> Bool {
        ["view.", "list.", "member.", "tag.", "prefs.", "key."].contains { op.name.hasPrefix($0) }
    }

    // MARK: - Reading

    /// Read everything again: who is signed in and their lists, the desk, and every open todo;
    /// then send what waits. A different person than the cache's starts from nothing.
    public func refresh() async {
        guard let backend else { return }
        do {
            let answer = try await backend.todosMe()
            if let known = me?.principal, known != answer.principal { forgetCache() }
            me = answer
            cursor = max(cursor, answer.seq)
            applyToday(try await backend.todosToday())
            try await readOpenTodos(backend)
            signedOut = false
            offline = false
            recompute()
            storage.saveCache(cacheSnapshot())
        } catch {
            note(error)
        }
        await drain()
    }

    /// Ask the feed what happened since the last read, and read again what it names. The phone's
    /// own changes are not news.
    public func catchUp() async {
        guard let backend, me != nil else { return }
        do {
            let answer = try await backend.todosEvents(after: cursor)
            if answer.reset {
                await refresh()
                return
            }
            cursor = max(cursor, answer.head)
            let own = Set(appliedIds)
            let effect = TodosOverlay.effectOfEvents(answer.events.filter { !own.contains($0.changeId) })
            if !effect.todoIds.isEmpty {
                await refresh()
            } else if effect.refreshMe {
                await refreshMe()
            }
        } catch {
            note(error)
        }
    }

    private func refreshMe() async {
        guard let backend else { return }
        do {
            me = try await backend.todosMe()
            recompute()
            storage.saveCache(cacheSnapshot())
        } catch {
            note(error)
        }
    }

    private func refreshToday() async {
        guard let backend else { return }
        do {
            applyToday(try await backend.todosToday())
            recompute()
            storage.saveCache(cacheSnapshot())
        } catch {
            note(error)
        }
    }

    private func note(_ error: Error) {
        switch TodosFailure.of(error) {
        case .retry: offline = true
        case .signedOut: signedOut = true
        case .refused: break
        }
    }

    /// The last `/today` answer, kept whole for the cache.
    @ObservationIgnored private var lastToday: TodosTodayAnswer?

    private func applyToday(_ answer: TodosTodayAnswer) {
        lastToday = answer
        merge(Array(answer.todos.values) + answer.due)
        serverDesk = answer.desk
        dueIds = answer.due.map(\.id)
        day = answer.day
        cursor = max(cursor, answer.seq)
        settling.removeAll { $0.seq <= answer.seq }
    }

    /// Every open todo, page by page. Afterwards the cache holds these, the desk's and the due
    /// strip's, and whatever an answer newer than this read carried; a row the read no longer
    /// returns was closed, deleted or moved out of reach.
    private func readOpenTodos(_ backend: any TodosBackend) async throws {
        var rows: [Todo] = []
        var page: String?
        var readAt = 0
        repeat {
            let answer = try await backend.todosQuery(
                TodosQueryRequest(
                    q: Self.openTodosQuery, scope: nil, group: "none", tree: "flat", limit: Self.openPageSize,
                    cursor: page))
            rows += answer.todos
            readAt = max(readAt, answer.seq)
            page = answer.nextCursor
        } while page != nil
        let keep = Set(serverDesk.compactMap(\.todoId)).union(dueIds)
        var next: [String: Todo] = [:]
        for todo in base.values where todo.updatedSeq > readAt || keep.contains(todo.id) { next[todo.id] = todo }
        base = next
        merge(rows)
    }

    /// Merge rows an answer carried; an older version never replaces a newer one.
    private func merge(_ rows: [Todo]) {
        guard !rows.isEmpty else { return }
        for row in rows {
            if let known = base[row.id], known.updatedSeq > row.updatedSeq { continue }
            base[row.id] = row
        }
        recompute()
    }

    private func cacheSnapshot() -> TodosCache {
        TodosCache(me: me, today: lastToday, todos: base)
    }

    private func recompute() {
        let context = TodosOverlay.Context(
            defaultListId: me?.prefs?.defaultListId, now: IsoTimestamp.utcString(from: now()),
            principal: me?.principal, displayName: me?.displayName)
        var next = base
        for (id, row) in TodosOverlay.overlayTodos(base: base, changes: queue, context: context) { next[id] = row }
        todos = next
        deskItems = TodosOverlay.applyDeskOps(serverDesk, changes: settling.map(\.change) + queue, todos: next)
    }

    /// The person's day now, by their preferences; nil while they are unknown.
    private func currentDay() -> String? {
        guard let prefs = me?.prefs else { return nil }
        return TodosOverlay.dayOf(now(), timezone: prefs.timezone, rollover: prefs.dayRollover)
    }

    // MARK: - Reading what is held

    /// The lists the person may see.
    public var lists: [TodoList] { me?.lists ?? [] }

    /// The todos a queued change still touches: rows to mark as not yet saved.
    public var pendingIds: Set<String> {
        var ids = Set<String>()
        for change in queue {
            if let capture = change.capture, change.ops.isEmpty { ids.insert(capture.todoId) }
            for op in change.ops { ids.formUnion(TodosOverlay.opTodoIds(op)) }
        }
        return ids
    }

    /// A UUIDv7: 48 bits of millisecond time, then randomness, so ids this phone makes sort by
    /// creation. The server accepts any version; the order is a courtesy to the log.
    public nonisolated static func uuidv7(now: Date = Date()) -> String {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        var milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        for index in stride(from: 5, through: 0, by: -1) {
            bytes[index] = UInt8(milliseconds & 0xff)
            milliseconds >>= 8
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(
                hex[
                    hex.index(
                        hex.startIndex, offsetBy: range.lowerBound)..<hex.index(
                            hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }
}
