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

    /// What each page (a view or a list) last read, by `TodoPage.key`: the ids and groups the
    /// server returned. Views are evaluated on the server only; a page asks again on `readTick`.
    public private(set) var results: [String: TodoPageResult] = [:]
    /// A page's last read failed: why, by key. Kept beside the result it could not replace.
    public private(set) var resultErrors: [String: String] = [:]
    /// The open children of the todos whose children were read, by rank.
    public private(set) var childIds: [String: [String]] = [:]
    /// The number beside each view (`GET /views/counts`), by view id; absent for a view of days.
    public private(set) var viewCounts: [String: Int] = [:]
    /// Counts up whenever what a page shows may have changed: a change the server took, or a read
    /// that found news. Pages ask again when it moves.
    public private(set) var readTick = 0
    /// Todos created on a page and applied, drawn there until a read of that page at or after
    /// their last event holds them, so a new row does not blink out between the answer and the read.
    @ObservationIgnored private var heldCreates: [(todoId: String, page: String, seq: Int)] = []

    /// What each open todo's sheet last read: the todo, its nudges, all its children, its changes.
    public private(set) var details: [String: TodosDetailAnswer] = [:]
    /// The days ahead and the Logbook, as last read.
    public private(set) var upcoming: TodosUpcomingAnswer?
    public private(set) var logbook: TodosLogbookAnswer?
    /// The Logbook's todos, kept apart from the open ones the cache holds.
    public private(set) var logbookTodos: [String: Todo] = [:]
    /// Subtasks a change created, drawn under their parent until a read of the parent's children
    /// that began after the change was applied holds them, so a new subtask does not blink out.
    @ObservationIgnored private var heldChildren: [(todoId: String, parent: String, applied: Int)] = []
    /// Counts reads and applied changes, in the order they happen.
    @ObservationIgnored private var moment = 0

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
        results = cache?.results ?? [:]
        childIds = cache?.children ?? [:]
        viewCounts = cache?.viewCounts ?? [:]
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
    /// out. `place` is the page it was typed on: its view's defaults and its list apply as on the
    /// web; `dismissed` names the ones left off this todo. `description` goes under whatever
    /// the words themselves put in the body, `picks` are a sheet's pickers' choices, and
    /// `deskPosition` puts the new todo on the desk at that place. Returns the change's id.
    @discardableResult
    public func capture(
        text: String, place: TodoCreatePlace = .anywhere, dismissed: Set<String> = [], links: [TodoLinkSpec] = [],
        parsed: TodosParseAnswer? = nil, description: String = "", picks: TodoAddDraft = TodoAddDraft(),
        deskPosition: TodoPosition? = nil, source: TodosSource = .ios
    ) -> String {
        let (words, rest) = Self.split(text)
        let body = [rest, description.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let capture = TodosCapture(
            text: words, body: body.isEmpty ? nil : body, todoId: makeId(), list: place.listId, place: place,
            links: links, day: currentDay(), dismissed: dismissed.sorted(), picks: picks.isEmpty ? nil : picks,
            deskPosition: deskPosition?.json)
        let ops = parsed.map { Self.ops(of: capture, create: createOp(capture, from: $0)) } ?? []
        return enqueue(
            TodosQueuedChange(
                changeId: makeId(), summary: nil, ops: ops, capture: capture, source: source.rawValue,
                principal: confirmedPrincipal, queuedAt: IsoTimestamp.utcString(from: now())))
    }

    /// A capture's words and what comes after them: the first non-empty line, with the lines
    /// after it as the body. However long the line is, it goes out whole: the server keeps what
    /// fits in a title and moves the rest to the description (`TodoTitles`).
    static func split(_ text: String) -> (words: String, body: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        let first = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let rest = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (first, rest.isEmpty ? nil : rest)
    }

    /// A capture's change: its `todo.create`, and the `desk.add` that places it on the desk when
    /// it was added into a section.
    static func ops(of capture: TodosCapture, create: TodoOp) -> [TodoOp] {
        guard let position = capture.deskPosition else { return [create] }
        return [
            create, TodoOp(fields: ["op": .string("desk.add"), "todo": .string(capture.todoId), "position": position]),
        ]
    }

    /// Attach a file to a todo, one the queue is still to create included: the bytes are kept
    /// on the phone, sent under their hash, and then named by one `attachment.add`. Returns the
    /// change's id, or nil when the bytes could not be kept.
    @discardableResult
    public func attach(todoId: String, name: String, contentType: String, data: Data) -> String? {
        let sha256 = TodoBlobs.sha256Hex(data)
        guard storage.saveBlob(data, sha256: sha256) else { return nil }
        let blob = TodosQueuedBlob(
            id: makeId(), todoId: todoId, sha256: sha256, name: TodoBlobs.name(name), contentType: contentType,
            size: data.count)
        let op = TodoOp(fields: [
            "op": .string("attachment.add"), "id": .string(blob.id), "todo": .string(todoId),
            "blob": .string(sha256), "name": .string(blob.name),
        ])
        return enqueue(
            TodosQueuedChange(
                changeId: makeId(), summary: nil, ops: [op], source: TodosSource.ios.rawValue,
                principal: confirmedPrincipal, queuedAt: IsoTimestamp.utcString(from: now()), blobs: [blob]))
    }

    /// The files queued for a todo that the server has not attached yet.
    public func queuedFiles(of todoId: String) -> [TodosQueuedBlob] {
        queue.flatMap { $0.blobs ?? [] }.filter { $0.todoId == todoId }
    }

    /// Takes a change's file bytes off the phone once no queued change names them.
    private func releaseBlobs(of change: TodosQueuedChange) {
        for blob in change.blobs ?? []
        where !queue.contains(where: { $0.blobs?.contains { $0.sha256 == blob.sha256 } == true }) {
            storage.removeBlob(sha256: blob.sha256)
        }
    }

    /// Sends a change's files ahead of it. Nil when they are all there; else what stops it.
    private func sendBlobs(of change: TodosQueuedChange, backend: any TodosBackend) async -> Error? {
        for blob in change.blobs ?? [] {
            guard let data = storage.loadBlob(sha256: blob.sha256) else {
                return TodosApiError(
                    statusCode: 422,
                    body: .plain("blob", "The file \u{201C}\(blob.name)\u{201D} is no longer on this iPhone."))
            }
            do {
                try await backend.todosPutBlob(sha256: blob.sha256, data: data, contentType: blob.contentType)
            } catch {
                return error
            }
        }
        return nil
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

    /// Plain words read into todos by the server's model (`POST /compose`), laid over the place's
    /// defaults as every add is, and queued as ONE change, so one Undo takes all of it back.
    /// Throws without queueing anything when there is no connection to ask or the model read no
    /// todo; the caller keeps the words then.
    public func compose(text: String, place: TodoCreatePlace = .anywhere, source: TodosSource = .ios) async throws
        -> TodosComposed
    {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw TodosComposeFailure.nothingRead }
        guard let backend else { throw TodosComposeFailure.unreachable }
        let answer: TodosComposeAnswer
        do {
            answer = try await backend.todosCompose(TodosComposeRequest(text: words, list: place.listId))
        } catch {
            throw TodosComposeFailure.of(error)
        }
        let ops = TodoCreate.withViewDefaults(
            answer.ops.filter { $0.name == "todo.create" }, place: place, today: currentDay())
        guard let first = ops.first?.string("id") else { throw TodosComposeFailure.nothingRead }
        let changeId = submit(ops, source: source)
        return TodosComposed(changeId: changeId, firstTodoId: first, count: ops.count)
    }

    /// Plain words from a door that reports back (Siri, Shortcuts): read by the model when it can
    /// be asked, else queued as typed through the capture path, so nothing said is lost.
    public func describeAndWait(text: String, source: TodosSource, timeout: TimeInterval) async
        -> TodosCaptureOutcome
    {
        guard let composed = try? await compose(text: text, source: source) else {
            return await captureAndWait(text: text, source: source, timeout: timeout)
        }
        let outcome = await outcome(of: composed.changeId, timeout: timeout)
        guard composed.count > 1, outcome.added else { return outcome }
        return TodosCaptureOutcome(
            changeId: outcome.changeId, settlement: outcome.settlement, title: outcome.title,
            signedOut: outcome.signedOut, saved: outcome.saved, count: composed.count)
    }

    /// Take a queued change out before it was sent, for a door that lets the person change the
    /// words and try again. A change whose request is already on its way may still land.
    public func withdraw(changeId: String) {
        guard let change = queue.first(where: { $0.changeId == changeId }) else { return }
        remove(change)
        releaseBlobs(of: change)
    }

    /// Takes a change back, the web outbox's `undoChange`: one the server applied is undone as a
    /// new change (`strict`), one that never left the phone is taken out of the queue, and one
    /// being sent right now is waited for first. A change the server refused has nothing to undo.
    public func undo(changeId: String) async -> TodosUndoOutcome {
        if queue.contains(where: { $0.changeId == changeId }) {
            // Nothing in flight, or a later change than the one being sent: it never reached the
            // server, so taking it out of the queue is the whole undo.
            if drainTask == nil || queue.first?.changeId != changeId {
                withdraw(changeId: changeId)
                return .undone
            }
            switch await settled(changeId, timeout: Self.undoWaitSeconds) {
            case .applied: break
            case .refused: return .nothingToUndo
            case .waiting: return .failed
            }
        }
        guard let backend else { return .failed }
        appliedIds.removeAll { $0 == changeId }
        do {
            let result = try await backend.todosUndo(changeId: changeId, TodosUndoRequest(changeId: makeId()))
            merge(result.todos)
            readTick += 1
            scheduleCacheWrite()
            // The undo's own events (a desk put back, a repeat's day restored) read what they name.
            await catchUp()
            return .undone
        } catch {
            note(error)
            switch TodosFailure.of(error) {
            case .refused(let refusal), .serverError(let refusal): return .refused(refusal.message)
            case .retry, .signedOut: return .failed
            }
        }
    }

    /// A settings change (prefs, a list, its people, a tag, a favourite): queued like every
    /// change, and once applied `/me` is read again, which is where settings live. The server's
    /// events for one's own change are skipped by the feed, so nothing else would read them.
    @discardableResult
    public func applySettings(_ ops: [TodoOp], timeout: TimeInterval = 30) async -> TodosSettlement {
        let changeId = submit(ops)
        let settlement = await settled(changeId, timeout: timeout)
        if case .applied = settlement { await refreshMe() }
        return settlement
    }

    /// The people a list can be shared with; none when the server cannot be asked.
    public func people() async -> [TodoPerson] {
        guard let backend else { return [] }
        return (try? await backend.todosPeople().people) ?? []
    }

    /// How long an Undo pressed while its change is being sent waits for the server's answer.
    static let undoWaitSeconds: TimeInterval = 30

    /// The todo a queued change creates: a capture's, else its first `todo.create`.
    public func createdTodoId(ofChange changeId: String) -> String? {
        guard let change = queue.first(where: { $0.changeId == changeId }) else { return nil }
        return change.capture?.todoId ?? change.ops.first { $0.name == "todo.create" }?.string("id")
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
                head.ops = Self.ops(of: capture, create: op)
                replace(head)
            }
            let result: TodosApplyResult
            do {
                if let stopped = await sendBlobs(of: head, backend: backend) { throw stopped }
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
        guard let spokenOn, spokenOn == currentDay() else { return plainCreateOp(capture) }
        do {
            let answer = try await backend.todosParse(
                text: capture.text, list: capture.list, source: TodosSource(rawValue: change.source) ?? .ios)
            return createOp(capture, from: answer)
        } catch {
            switch TodosFailure.of(error) {
            case .retry:
                waitForNetwork()
                return nil
            case .signedOut:
                waitForSignIn()
                return nil
            case .refused, .serverError:
                return plainCreateOp(capture)
            }
        }
    }

    /// The parser's `todo.create` for a capture: its fields as the server read them, the
    /// capture's own id, the capture's list when the words named none, and its links. A line the
    /// parser read entirely as fields keeps the words as its title.
    func createOp(_ capture: TodosCapture, from answer: TodosParseAnswer) -> TodoOp {
        Self.createOp(capture, from: answer, today: currentDay())
    }

    func plainCreateOp(_ capture: TodosCapture) -> TodoOp {
        Self.plainCreateOp(capture, today: currentDay())
    }

    /// The parser's reading laid over the place it was typed in (`TodoCreate`), with the
    /// capture's own id, its body and its links. A line the parser read entirely as fields keeps
    /// the words as its title; a line that says "no date" leaves the view's day off.
    static func createOp(_ capture: TodosCapture, from answer: TodosParseAnswer, today: String?) -> TodoOp {
        var typed = TodoCreate.typed(from: answer)
        if answer.title.trimmingCharacters(in: .whitespaces).isEmpty { typed["title"] = .string(capture.text) }
        return finish(
            TodoCreate.op(
                id: capture.todoId, title: capture.text, place: capture.createPlace, today: today, typed: typed,
                dismissed: TodoCreate.cleared(Set(capture.dismissed), answer: answer)),
            capture)
    }

    static func plainCreateOp(_ capture: TodosCapture, today: String?) -> TodoOp {
        finish(
            TodoCreate.op(
                id: capture.todoId, title: capture.text, place: capture.createPlace, today: today,
                dismissed: Set(capture.dismissed)),
            capture)
    }

    private static func finish(_ op: TodoOp, _ capture: TodosCapture) -> TodoOp {
        var op = op
        if let picks = capture.picks { op = TodoCreate.withDraft(op, picks) }
        if let body = capture.body {
            let typed = op.string("body") ?? ""
            op = op.setting("body", .string(typed.isEmpty ? body : "\(typed)\n\n\(body)"))
        }
        return capture.links.isEmpty ? op : op.setting("links", .array(capture.links.map(\.json)))
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
            moment += 1
            for op in head.ops where op.name == "todo.create" {
                if let id = op.string("id"), let parent = op.string("parent") {
                    heldChildren.append((id, parent, moment))
                }
            }
            if let page = head.capture?.place?.page {
                for op in head.ops where op.name == "todo.create" {
                    if let id = op.string("id") { heldCreates.append((id, page, result.change?.seqLast ?? Int.max)) }
                }
            }
        }
        readTick += 1
        remove(head)
        releaseBlobs(of: head)
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
        releaseBlobs(of: head)
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
            readTick += 1
            await refreshViewCounts()
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
            if !effect.todoIds.isEmpty || effect.refreshMe { readTick += 1 }
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
        let keep = Set(serverDesk.compactMap(\.todoId)).union(dueIds).union(pageTodoIds())
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
        TodosCache(me: me, today: lastToday, todos: base, results: results, children: childIds, viewCounts: viewCounts)
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

    // MARK: - Pages

    /// Read a page's first page of rows again; the answer replaces what the page held unless an
    /// answer from later already did.
    public func loadPage(_ page: TodoPage) async {
        guard let backend else { return }
        do {
            let answer = try await fetch(page, cursor: nil, backend: backend)
            merge(answer.todos)
            if let held = results[page.key], held.seq > answer.seq { return }
            results[page.key] = TodoPageResult(
                groups: TodoPageResult.groups(of: answer), total: answer.total, nextCursor: answer.nextCursor,
                seq: answer.seq)
            resultErrors[page.key] = nil
            heldCreates.removeAll { $0.page == page.key && $0.seq <= answer.seq }
            scheduleCacheWrite()
        } catch {
            resultErrors[page.key] = Self.readFailure(error)
            note(error)
        }
    }

    /// The next rows of a page that has more.
    public func loadMore(_ page: TodoPage) async {
        guard let backend, let held = results[page.key], let cursor = held.nextCursor else { return }
        do {
            let answer = try await fetch(page, cursor: cursor, backend: backend)
            merge(answer.todos)
            results[page.key] = held.appending(TodoPageResult.groups(of: answer), nextCursor: answer.nextCursor)
            scheduleCacheWrite()
        } catch {
            note(error)
        }
    }

    private func fetch(_ page: TodoPage, cursor: String?, backend: any TodosBackend) async throws -> TodosQueryAnswer {
        switch page {
        case .view(let id): return try await backend.todosRunView(id: id, cursor: cursor)
        case .list(let id):
            return try await backend.todosQuery(
                TodosQueryRequest(q: "list:\(id)", group: "none", tree: "fold", cursor: cursor, activeScope: true))
        case .tag(let name):
            let quoted = name.contains(where: \.isWhitespace) ? "\"\(name)\"" : name
            return try await backend.todosQuery(
                TodosQueryRequest(q: "tag:\(quoted)", group: "none", tree: "fold", cursor: cursor, activeScope: true))
        }
    }

    /// Read a todo's open children, for a row opened to show them.
    public func loadChildren(of todoId: String) async {
        guard let backend else { return }
        moment += 1
        let started = moment
        do {
            let answer = try await backend.todosDetail(ref: todoId)
            let children = answer.children ?? []
            merge([answer.todo] + children)
            childIds[todoId] = children.map(\.id)
            heldChildren.removeAll { $0.parent == todoId && $0.applied < started }
            scheduleCacheWrite()
        } catch {
            note(error)
        }
    }

    /// Read a todo for its sheet: its nudges, every child (done ones after the open), its changes.
    /// The id of the todo numbered `number` (a link's `T-<n>`): from what is held, else read from
    /// the server. Nil when this person cannot see it or there is no connection.
    public func todoId(number: Int) async -> String? {
        if let held = todos.values.first(where: { $0.number == number }) { return held.id }
        guard let backend else { return nil }
        do {
            let answer = try await backend.todosDetail(ref: "T-\(number)")
            merge([answer.todo])
            return answer.todo.id
        } catch {
            note(error)
            return nil
        }
    }

    public func loadSheet(_ todoId: String) async {
        guard let backend else { return }
        moment += 1
        let started = moment
        do {
            let answer = try await backend.todosSheet(ref: todoId)
            let children = answer.children ?? []
            merge([answer.todo] + children)
            details[todoId] = answer
            childIds[todoId] = children.filter { $0.status == .open }.map(\.id)
            heldChildren.removeAll { $0.parent == todoId && $0.applied < started }
        } catch {
            note(error)
        }
    }

    /// A todo's children for its sheet, in the last read's order, with the ones a change made
    /// since (queued or held) after them.
    public func sheetChildren(of todoId: String) -> [String] {
        var ids = details[todoId]?.children?.map(\.id) ?? childIds[todoId] ?? []
        for held in heldChildren where held.parent == todoId && !ids.contains(held.todoId) { ids.append(held.todoId) }
        for change in queue {
            for op in change.ops where op.name == "todo.create" && op.string("parent") == todoId {
                if let id = op.string("id"), !ids.contains(id) { ids.append(id) }
            }
        }
        return ids
    }

    /// The caller's nudges on a todo, with queued sets and removes drawn over them.
    public func nudges(of todoId: String) -> [TodoNudge] {
        TodoWords.overlayNudges(details[todoId]?.nudges ?? [], ops: queue.flatMap(\.ops), todoId: todoId)
    }

    /// The days ahead (the server's ceiling is 92).
    public func loadUpcoming(days: Int = 30) async {
        guard let backend else { return }
        do {
            let answer = try await backend.todosUpcoming(days: days)
            merge(Array(answer.todos.values))
            upcoming = answer
        } catch {
            note(error)
        }
    }

    /// The Logbook's first page again, or its next page.
    public func loadLogbook(more: Bool = false) async {
        guard let backend else { return }
        let cursor = more ? logbook?.nextCursor : nil
        if more, cursor == nil { return }
        do {
            let answer = try await backend.todosLogbook(cursor: cursor)
            for (id, todo) in answer.todos { logbookTodos[id] = todo }
            if more, let held = logbook {
                var days = held.days
                for day in answer.days {
                    if let index = days.firstIndex(where: { $0.date == day.date }) {
                        days[index] = TodosLogbookAnswer.Day(date: day.date, entries: days[index].entries + day.entries)
                    } else {
                        days.append(day)
                    }
                }
                logbook = TodosLogbookAnswer(days: days, todos: [:], nextCursor: answer.nextCursor)
            } else {
                logbook = TodosLogbookAnswer(days: answer.days, todos: [:], nextCursor: answer.nextCursor)
            }
        } catch {
            note(error)
        }
    }

    /// The one search box's answer for what was typed.
    public func search(_ request: TodosSearchRequest) async throws -> TodosSearchAnswer {
        guard let backend else { throw PaiError.transport("Not signed in") }
        let answer = try await backend.todosSearch(request)
        merge(([answer.top].compactMap { $0 } + answer.todos + answer.fewer).map(\.todo).filter { $0.status == .open })
        return answer
    }

    /// Tells the server what was opened from search, which its zero state then lists as recent.
    /// Best effort: a lost call costs one line of that list.
    public func remember(_ kind: TodosRecent.Kind, target: String) {
        guard let backend else { return }
        Task { try? await backend.todosRecent(kind: kind, target: target) }
    }

    /// The numbers beside the views.
    public func refreshViewCounts() async {
        guard let backend, me?.prefs != nil else { return }
        do {
            let answer = try await backend.todosViewCounts()
            var counts: [String: Int] = [:]
            for view in answer.views { if let count = view.count { counts[view.id] = count } }
            viewCounts = counts
            scheduleCacheWrite()
        } catch {
            note(error)
        }
    }

    /// The todos made on `page` that its last read does not hold yet: queued ones and applied
    /// ones waiting for the next read, newest first, the way a new root goes first.
    public func pendingRows(on page: TodoPage) -> [String] {
        var ids: [String] = []
        for change in queue.reversed() where change.capture?.place?.page == page.key {
            if let id = change.ops.first(where: { $0.name == "todo.create" })?.string("id") ?? change.capture?.todoId {
                ids.append(id)
            }
        }
        for held in heldCreates.reversed() where held.page == page.key && !ids.contains(held.todoId) {
            ids.append(held.todoId)
        }
        let shown = Set(results[page.key]?.groups.flatMap(\.ids) ?? [])
        return ids.filter { !shown.contains($0) }
    }

    private func pageTodoIds() -> Set<String> {
        var ids = Set(results.values.flatMap { $0.groups.flatMap(\.ids) })
        for (parent, children) in childIds {
            ids.insert(parent)
            ids.formUnion(children)
        }
        return ids
    }

    static func readFailure(_ error: Error) -> String {
        switch TodosFailure.of(error) {
        case .retry: return "No connection: showing what this iPhone last read."
        case .signedOut: return "Signed out: showing what this iPhone last read."
        case .refused(let refusal), .serverError(let refusal): return refusal.message
        }
    }

    // MARK: - Reading what is held

    /// The person's day: what the server last said, else the day by their preferences now.
    public var personsToday: String {
        if let day { return day }
        return currentDay() ?? IsoTimestamp.utcString(from: now()).prefix(10).description
    }

    /// The person's time of day (`HH:mm`), by which a time of today counts as passed. After
    /// midnight and before their day turns, the whole of "today" lies behind them.
    public var personsClock: String? {
        guard let prefs = me?.prefs, let zone = TimeZone(identifier: prefs.timezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now())
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard date == personsToday else { return "24:00" }
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

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
/// What became of an Undo.
public enum TodosUndoOutcome: Equatable, Sendable {
    /// Taken back: undone on the server, or taken out of the queue before it was sent.
    case undone
    /// The server refused the change itself, so there is nothing to take back.
    case nothingToUndo
    /// The server refused the undo, said why (something changed since).
    case refused(String)
    /// No answer: no connection or no sign-in.
    case failed

    /// What the toast after an Undo says; nil says nothing.
    public var message: String? {
        switch self {
        case .undone: "Undone"
        case .nothingToUndo: nil
        case .refused(let message): message
        case .failed: "Could not undo; try again."
        }
    }
}

/// Why plain words did not become todos. Nothing was queued either way; the words stay with
/// the person.
public enum TodosComposeFailure: Error, Equatable, Sendable {
    /// No answer from the server: the words can still be added as typed.
    case unreachable
    /// The sign-in is gone.
    case signedOut
    /// The server asked its models and none answered (503 `unavailable`).
    case unread
    /// The model answered and read no todo in the words.
    case nothingRead
    /// The server refused the words, in its own sentence.
    case refused(String)

    static func of(_ error: Error) -> TodosComposeFailure {
        if let refusal = error as? TodosApiError, refusal.code == "unavailable" { return .unread }
        switch TodosFailure.of(error) {
        case .retry: return .unreachable
        case .signedOut: return .signedOut
        case .refused(let refusal), .serverError(let refusal): return .refused(refusal.message)
        }
    }

    /// What the sheet says; the words are kept in every case.
    public var message: String {
        switch self {
        case .unreachable: "The server could not be reached to read the words. They are kept."
        case .signedOut: "You are signed out, so the words were not read. They are kept."
        case .unread: "The model did not answer. Your words are kept."
        case .nothingRead: "The model found no todo in these words. They are kept."
        case .refused(let reason): "Not read: \(reason) Your words are kept."
        }
    }
}

/// Plain words queued as todos: the one change, the first todo (the one to open), and how many.
public struct TodosComposed: Equatable, Sendable {
    public let changeId: String
    public let firstTodoId: String
    public let count: Int
}

public struct TodosCaptureOutcome: Equatable, Sendable {
    public let changeId: String
    public let settlement: TodosSettlement
    /// The todo's title as the server made it, or the captured words while it waits.
    public let title: String
    /// The wait ended on a lost sign-in rather than a missing network.
    public let signedOut: Bool
    /// The capture reached the disk. When it did not, it exists only while this process lives.
    public let saved: Bool
    /// How many todos the change made: more than one when plain words were read as several.
    public var count = 1

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
        case .applied where count > 1:
            return "Added \(count) todos, first \u{201C}\(title)\u{201D}."
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
