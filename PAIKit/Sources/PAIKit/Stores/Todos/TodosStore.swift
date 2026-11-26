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
    /// The last write of the queue to disk failed: what is queued now exists only in memory.
    public private(set) var unsaved = false

    /// Told the reason, and the words a person typed or spoke into it, when the server refuses a
    /// change nobody is waiting on (`settled`). A door that waits tells its own verdict.
    public var onRefusal: (@MainActor (TodosRefusal, _ words: String?) -> Void)?

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
    @ObservationIgnored private var drainToken: UUID?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Who the current connection's credential is, once a `/me` through it answered; nil until
    /// then. A change queued by a person goes out only when this is that person.
    @ObservationIgnored private var confirmedPrincipal: String?
    /// Server errors (500) met per change, so a hiccup is retried and a broken change is not
    /// retried forever.
    @ObservationIgnored private var serverErrors: [String: Int] = [:]
    @ObservationIgnored private var cacheWrite: Task<Void, Never>?

    /// Resend delays after a dropped connection; the last one repeats.
    public static let retryDelaysSeconds: [TimeInterval] = [1, 2, 5, 15, 30]
    /// How often a queue held back by an expired sign-in tries again.
    public static let signedOutRetrySeconds: TimeInterval = 30
    static let rememberedOutcomes = 30
    static let undoDepth = 50
    static let refusedKept = 50
    /// One query page; the server's ceiling.
    static let openPageSize = 1000
    /// More pages than any person's open todos fill; a cursor that never ends stops here.
    static let openPagesMax = 20
    /// How often a change meeting a server error is sent before it counts as refused.
    static let serverErrorAttempts = 5
    /// The cache is written this long after the last change to it, not on every answer.
    static let cacheWriteDelaySeconds: TimeInterval = 1
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
        confirmedPrincipal = nil
        signedOut = false
        Task { await drain() }
    }

    /// The sign-in ended: nothing is sent until the next `connect`, and nothing queued is lost.
    public func disconnect() {
        backend = nil
        confirmedPrincipal = nil
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
        cacheWrite?.cancel()
        cacheWrite = nil
        storage.saveCache(nil)
        recompute()
    }

    // MARK: - Writing

    /// Queue a change and start sending it. Returns its id.
    @discardableResult
    public func submit(_ ops: [TodoOp], summary: String? = nil, source: TodosSource = .ios) -> String {
        enqueue(
            TodosQueuedChange(
                changeId: makeId(), summary: summary, ops: ops, source: source.rawValue, principal: confirmedPrincipal,
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
        let (words, body) = Self.split(text)
        let capture = TodosCapture(
            text: words, body: body, todoId: makeId(), list: list, links: links, day: currentDay())
        let ops = parsed.map { [Self.createOp(capture, from: $0)] } ?? []
        return enqueue(
            TodosQueuedChange(
                changeId: makeId(), summary: nil, ops: ops, capture: capture, source: source.rawValue,
                principal: confirmedPrincipal, queuedAt: IsoTimestamp.utcString(from: now())))
    }

    /// The longest first line kept as the words; a title may hold 500 characters, and the parser
    /// reads the line before the server counts it.
    static let wordsLimit = 400

    /// A capture's words and what does not fit in them: the first non-empty line, with the
    /// lines after it as the body; a first line too long for a title is cut, and the whole text
    /// becomes the body.
    static func split(_ text: String) -> (words: String, body: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        let first = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let rest = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard first.count <= wordsLimit else { return (String(first.prefix(wordsLimit)), trimmed) }
        return (first, rest.isEmpty ? nil : rest)
    }

    /// Capture, then wait up to `timeout` seconds for the server's verdict, for a door that
    /// reports back (Siri, the share sheet). The capture is queued, on disk, before anything is
    /// asked of the network; words that are only spaces queue nothing.
    public func captureAndWait(
        text: String, links: [TodoLinkSpec] = [], source: TodosSource, timeout: TimeInterval
    ) async -> TodosCaptureOutcome {
        guard !Self.split(text).words.isEmpty else {
            return TodosCaptureOutcome(
                changeId: "", settlement: .refused(TodosRefusal(code: "empty", message: "There are no words to add.")),
                title: "", signedOut: signedOut, saved: true)
        }
        return await outcome(of: capture(text: text, links: links, source: source), timeout: timeout)
    }

    /// Take a queued change out before it was sent, for a door that lets the person change the
    /// words and try again. A change whose request is already on its way may still land.
    public func withdraw(changeId: String) {
        guard let change = queue.first(where: { $0.changeId == changeId }) else { return }
        remove(change)
    }

    /// Wait up to `timeout` seconds for a queued capture's verdict, and name the todo it made.
    public func outcome(of changeId: String, timeout: TimeInterval) async -> TodosCaptureOutcome {
        let capture = queue.first { $0.changeId == changeId }?.capture
        let saved = !unsaved
        let settlement = await settled(changeId, timeout: timeout)
        var title = capture?.text ?? ""
        if case .applied(let result?) = settlement,
            let made = result.todos.first(where: { $0.id == capture?.todoId }) ?? result.todos.first
        {
            title = made.title
        }
        return TodosCaptureOutcome(
            changeId: changeId, settlement: settlement, title: title, signedOut: signedOut, saved: saved)
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
        persistQueue()
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

    /// Everyone waiting hears "waiting" at once: the send stopped for want of a network or a
    /// sign-in, and waiting out the timeout would tell them nothing more.
    private func releaseWaiters() {
        for token in waiters.keys { finishWaiter(token, .waiting) }
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
        // Cleared by the task itself the moment it ends: cleared by the caller after its await,
        // a finished task would stay in place for a while, and a drain joining it would send
        // nothing.
        let token = UUID()
        drainToken = token
        let task = Task {
            await sendQueue()
            if drainToken == token { drainTask = nil }
        }
        drainTask = task
        await task.value
    }

    private func sendQueue() async {
        retryTask?.cancel()
        retryTask = nil
        var acceptedDesk = false
        var acceptedReference = false
        if let backend, confirmedPrincipal == nil, !queue.isEmpty {
            guard await confirmIdentity(backend) else { return }
        }
        while let backend, let index = nextSendable() {
            var head = queue[index]
            if head.ops.isEmpty, let capture = head.capture {
                guard let op = await readCapture(capture, of: head, backend: backend) else { return }
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
                case .serverError(let refusal):
                    let attempts = (serverErrors[head.changeId] ?? 0) + 1
                    serverErrors[head.changeId] = attempts
                    guard attempts >= Self.serverErrorAttempts else {
                        waitForServer()
                        return
                    }
                    drop(head, refusal, current: nil)
                    continue
                }
            }
            serverErrors[head.changeId] = nil
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

    /// The first change that may go out as whoever is signed in now. A change queued by a
    /// person waits until a `/me` through this connection said it is that person; one queued
    /// while nobody was confirmed goes out as the next person.
    private func nextSendable() -> Int? {
        queue.firstIndex { $0.principal == nil || ($0.principal == confirmedPrincipal && confirmedPrincipal != nil) }
    }

    /// Ask who this connection's credential is before sending anything. False when the answer
    /// did not come; the send waits.
    private func confirmIdentity(_ backend: any TodosBackend) async -> Bool {
        do {
            adoptMe(try await backend.todosMe())
            return true
        } catch {
            switch TodosFailure.of(error) {
            case .retry, .serverError: waitForNetwork()
            case .signedOut: waitForSignIn()
            case .refused: note(error)
            }
            return false
        }
    }

    /// A `/me` answer through this connection: who is signed in. A different person than the
    /// cache's starts from nothing; the queue stays, guarded by who queued each change.
    private func adoptMe(_ answer: TodosMeAnswer) {
        if let known = me?.principal, known != answer.principal { forgetCache() }
        me = answer
        confirmedPrincipal = answer.principal
        cursor = max(cursor, answer.seq)
        recompute()
        scheduleCacheWrite()
    }

    /// The capture's `todo.create`, read by the parser when it is still the day it was spoken on;
    /// its words as the title when not, or when the parser refuses. Nil when the parser could not
    /// be reached: the change waits.
    ///
    /// The day it was spoken on is the capture's own when the person's preferences were known
    /// then, else the day of its queueing by the preferences known now.
    private func readCapture(
        _ capture: TodosCapture, of change: TodosQueuedChange, backend: any TodosBackend
    ) async -> TodoOp? {
        let spokenOn = capture.day ?? IsoTimestamp.date(from: change.queuedAt).flatMap(personsDay(of:))
        guard let spokenOn, spokenOn == currentDay() else { return Self.plainCreateOp(capture) }
        do {
            let answer = try await backend.todosParse(
                text: capture.text, list: capture.list, source: TodosSource(rawValue: change.source) ?? .ios)
            return Self.createOp(capture, from: answer)
        } catch {
            switch TodosFailure.of(error) {
            case .retry:
                waitForNetwork()
                return nil
            case .signedOut:
                waitForSignIn()
                return nil
            case .refused, .serverError:
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
        if op.string("body") == nil, let body = capture.body { op = op.setting("body", .string(body)) }
        op = op.setting("created_at", .null).withoutEmptyFields()
        return capture.links.isEmpty ? op : op.setting("links", .array(capture.links.map(\.json)))
    }

    static func plainCreateOp(_ capture: TodosCapture) -> TodoOp {
        .create(id: capture.todoId, title: capture.text, body: capture.body, list: capture.list, links: capture.links)
    }

    private func waitForNetwork() {
        offline = true
        backOff()
    }

    /// The network is up and the server failed: try again after the same backoff.
    private func waitForServer() {
        offline = false
        backOff()
    }

    private func backOff() {
        let delays = Self.retryDelaysSeconds
        let delay = delays[min(failures, delays.count - 1)]
        failures += 1
        scheduleRetry(after: delay)
        releaseWaiters()
    }

    private func waitForSignIn() {
        signedOut = true
        offline = false
        scheduleRetry(after: Self.signedOutRetrySeconds)
        releaseWaiters()
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
        let told = isAwaited(head.changeId)
        settle(head.changeId, .applied(result))
        let failed = result?.results.filter { !$0.ok } ?? []
        if let result, !failed.isEmpty, !told {
            onRefusal?(
                TodosRefusal(code: nil, message: "\(failed.count) of \(result.of) changes were not applied."),
                Self.wordsOf(head))
        }
        scheduleCacheWrite()
    }

    private func isAwaited(_ changeId: String) -> Bool {
        waiters.values.contains { $0.changeId == changeId }
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
        serverErrors[head.changeId] = nil
        remove(head)
        let told = isAwaited(head.changeId)
        settle(head.changeId, .refused(refusal))
        if !told { onRefusal?(refusal, Self.wordsOf(head)) }
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
        persistQueue()
        recompute()
    }

    private func remove(_ change: TodosQueuedChange) {
        queue.removeAll { $0.changeId == change.changeId }
        persistQueue()
        recompute()
    }

    private func persistQueue() {
        unsaved = !storage.saveQueue(queue)
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
    /// True when every read answered.
    @discardableResult
    public func refresh() async -> Bool {
        guard let backend else { return false }
        var complete = false
        do {
            adoptMe(try await backend.todosMe())
            applyToday(try await backend.todosToday())
            try await readOpenTodos(backend)
            signedOut = false
            offline = false
            recompute()
            scheduleCacheWrite()
            complete = true
        } catch {
            note(error)
        }
        await drain()
        return complete
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
            let own = Set(appliedIds)
            let effect = TodosOverlay.effectOfEvents(answer.events.filter { !own.contains($0.changeId) })
            // The cursor moves past the events only once what they name was read again, so a
            // read that failed is asked for again by the next catch-up.
            var read = true
            if !effect.todoIds.isEmpty {
                read = await refresh()
            } else if effect.refreshMe {
                read = await refreshMe()
            }
            if read { cursor = max(cursor, answer.head) }
        } catch {
            note(error)
        }
    }

    @discardableResult
    private func refreshMe() async -> Bool {
        guard let backend else { return false }
        do {
            adoptMe(try await backend.todosMe())
            return true
        } catch {
            note(error)
            return false
        }
    }

    private func refreshToday() async {
        guard let backend else { return }
        do {
            applyToday(try await backend.todosToday())
            recompute()
            scheduleCacheWrite()
        } catch {
            note(error)
        }
    }

    /// Write the cache a moment after the last change to it: every accepted change and read
    /// touches it, and it is the whole open-todo set.
    private func scheduleCacheWrite() {
        cacheWrite?.cancel()
        cacheWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.cacheWriteDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushCache()
        }
    }

    /// Write the cache now, for the app leaving the screen.
    public func flushCache() {
        cacheWrite?.cancel()
        cacheWrite = nil
        storage.saveCache(cacheSnapshot())
    }

    private func note(_ error: Error) {
        switch TodosFailure.of(error) {
        case .retry: offline = true
        case .signedOut: signedOut = true
        case .refused, .serverError: break
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
        var pages = 0
        repeat {
            let answer = try await backend.todosQuery(
                TodosQueryRequest(
                    q: Self.openTodosQuery, scope: nil, group: "none", tree: "flat", limit: Self.openPageSize,
                    cursor: page))
            rows += answer.todos
            readAt = max(readAt, answer.seq)
            page = answer.nextCursor
            pages += 1
        } while page != nil && pages < Self.openPagesMax
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
    private func currentDay() -> String? { personsDay(of: now()) }

    private func personsDay(of instant: Date) -> String? {
        guard let prefs = me?.prefs else { return nil }
        return TodosOverlay.dayOf(instant, timezone: prefs.timezone, rollover: prefs.dayRollover)
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

/// What became of a capture a door waited on, and the sentence it tells the person.
public struct TodosCaptureOutcome: Equatable, Sendable {
    public let changeId: String
    public let settlement: TodosSettlement
    /// The todo's title as the server made it, or the captured words while it waits.
    public let title: String
    /// The wait ended on a lost sign-in rather than a missing network.
    public let signedOut: Bool
    /// The capture reached the disk. When it did not, it exists only while this process lives.
    public let saved: Bool

    /// Which door asks, which decides what a capture that could not go out yet means: the app on
    /// screen sends it by itself once it can; an intent's process is suspended soon after it
    /// answers, so the capture goes out when PAI is next opened; the share sheet queues nothing
    /// and offers to try again.
    public enum Keeper: Sendable {
        case app, intent, shareSheet
    }

    public var added: Bool {
        if case .applied = settlement { return true }
        return false
    }

    public func message(keeper: Keeper) -> String {
        switch settlement {
        case .applied:
            return "Added \u{201C}\(title)\u{201D}."
        case .refused(let refusal):
            return "Not added: \(refusal.message)"
        case .waiting:
            if !saved, keeper != .shareSheet { return "Could not save this todo on the iPhone. Add it again in PAI." }
            switch (keeper, signedOut) {
            case (.app, false): return "Saved on this iPhone. It is added once there is a connection."
            case (.app, true): return "Saved on this iPhone. It is added once you sign in to PAI again."
            case (.intent, false): return "Saved on this iPhone. Open PAI when there is a connection to send it."
            case (.intent, true): return "Saved on this iPhone. Open PAI and sign in again to send it."
            case (.shareSheet, false): return "Not added yet: there is no connection. Try again, or copy the text."
            case (.shareSheet, true): return "Not added: open PAI and sign in again, then share again."
            }
        }
    }
}
