import Foundation

/// The web's optimistic layer (`store/optimistic.ts`, `store/deskOrder.ts`) and feed reading
/// (`effectOfEvents` in `store/entities.ts`), by the same names: what the person sees while
/// changes are still queued is the server's rows with every queued op applied in order. A change
/// leaving the queue takes its drawing with it, so a rollback is removing the change.
public enum TodosOverlay {

    /// What drawing a change needs beyond the queue itself.
    public struct Context: Sendable {
        /// The caller's default list, for a create that names none.
        public var defaultListId: String?
        /// ISO-8601, UTC.
        public var now: String
        public var principal: String?
        public var displayName: String?

        public init(defaultListId: String?, now: String, principal: String?, displayName: String?) {
            self.defaultListId = defaultListId
            self.now = now
            self.principal = principal
            self.displayName = displayName
        }
    }

    /// The todos the queue touches, after every queued op in order; an id absent from the result
    /// is untouched. A capture the parser has not read yet is drawn as a todo titled with its words.
    public static func overlayTodos(
        base: [String: Todo], changes: [TodosQueuedChange], context: Context
    ) -> [String: Todo] {
        var overlay: [String: Todo] = [:]
        func lookup(_ id: String) -> Todo? { overlay[id] ?? base[id] }
        for change in changes {
            if let capture = change.capture, change.ops.isEmpty {
                if lookup(capture.todoId) == nil {
                    let op = TodoOp.create(id: capture.todoId, title: capture.text, list: capture.list)
                    overlay[capture.todoId] = newRow(op, context: context, source: change.source, lookup: lookup)
                }
                continue
            }
            for op in change.ops {
                if op.name == "todo.create" {
                    if let id = op.string("id"), lookup(id) == nil {
                        overlay[id] = newRow(op, context: context, source: change.source, lookup: lookup)
                    }
                    continue
                }
                for id in opTodoIds(op) {
                    if let current = lookup(id) {
                        overlay[id] = applyOne(current, op, context: context, lookup: lookup)
                    }
                }
            }
        }
        return overlay
    }

    /// The ids of the todos an op acts on (a create names its own new id).
    public static func opTodoIds(_ op: TodoOp) -> [String] {
        switch op.name {
        case "todo.create": return op.string("id").map { [$0] } ?? []
        case "desk.remove", "desk.move": return op.string("item").map { [$0] } ?? []
        case "todo.update", "todo.body", "todo.complete", "todo.skip", "todo.reopen", "todo.delete", "todo.restore",
            "todo.move", "todo.tag", "desk.add", "nudge.set":
            return op.string("todo").map { [$0] } ?? []
        default: return []
        }
    }

    /// First non-empty line of a markdown body, cut like the server's `body_preview`.
    static func bodyPreview(_ body: String) -> String {
        let line = body.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String((line ?? "").trimmingCharacters(in: .whitespaces).prefix(200))
    }

    private static func newRow(
        _ op: TodoOp, context: Context, source: String, lookup: (String) -> Todo?
    ) -> Todo {
        let id = op.string("id") ?? ""
        let parent = op.string("parent").flatMap(lookup)
        let body = op.string("body")
        return Todo(
            id: id, number: nil, ref: nil,
            listId: op.string("list") ?? parent?.listId ?? context.defaultListId ?? "",
            parentId: parent?.id, rootId: parent?.rootId ?? id, depth: parent.map { $0.depth + 1 } ?? 0, rank: "",
            title: op.string("title") ?? "", bodyPreview: bodyPreview(body ?? ""), body: body, bodyHash: "",
            status: .open, inbox: op.bool("inbox") ?? false,
            horizon: op.string("horizon").map { TodoHorizon.knownValues[$0] ?? .unrecognized($0) } ?? .whenever,
            when: op.decoded("when", as: TodoWhen.self), someday: op.bool("someday") ?? false,
            deadline: op.decoded("deadline", as: TodoDeadline.self), repeat: op.decoded("repeat", as: TodoRepeat.self),
            tags: op.strings("tags") ?? [], inheritedTags: [], links: [], attachments: [], childrenOpen: 0,
            childrenTotal: 0, checklist: nil, completedAt: nil, completedCount: 0, lastDoneAt: nil,
            key: op.string("key"),
            created: TodoCreated(
                at: context.now, by: context.principal ?? "", kind: .human, label: context.displayName ?? "",
                source: source, sessionId: nil),
            updatedAt: context.now, updatedSeq: 0, version: 0, asleep: false, inBand: false,
            onDesk: op.bool("desk") ?? false,
            hasNudge: !(op.decoded("nudges", as: [PaiJSONValue].self) ?? []).isEmpty, context: nil, foldedIds: nil)
    }

    private static func withTags(_ tags: [String], add: [String], remove: [String]) -> [String] {
        let gone = Set(remove.map { $0.lowercased() })
        var kept = tags.filter { !gone.contains($0.lowercased()) }
        var have = Set(kept.map { $0.lowercased() })
        for name in add where !have.contains(name.lowercased()) {
            kept.append(name)
            have.insert(name.lowercased())
        }
        return kept
    }

    /// The todo after one op. Only what the client can know is changed: a repeating todo's tick
    /// moves its date on the server, so it stays as it is until the answer arrives.
    private static func applyOne(_ todo: Todo, _ op: TodoOp, context: Context, lookup: (String) -> Todo?) -> Todo {
        var next = todo
        switch op.name {
        case "todo.update":
            guard let set = op.object("set") else { return todo }
            if let title = set.string("title") { next.title = title }
            if let horizon = set.string("horizon") {
                next.horizon = TodoHorizon.knownValues[horizon] ?? .unrecognized(horizon)
            }
            if set.has("when") { next.when = set.decoded("when", as: TodoWhen.self) }
            if let someday = set.bool("someday") { next.someday = someday }
            if set.has("deadline") { next.deadline = set.decoded("deadline", as: TodoDeadline.self) }
            if set.has("repeat") { next.repeat = set.decoded("repeat", as: TodoRepeat.self) }
            if let inbox = set.bool("inbox") { next.inbox = inbox }
        case "todo.body":
            if let body = op.string("set") {
                next.body = body
                next.bodyPreview = bodyPreview(body)
            }
        case "todo.complete":
            if todo.repeat != nil { return todo }
            next.status = op.string("as") == "dropped" ? .dropped : .done
            next.completedAt = op.string("at") ?? context.now
        case "todo.reopen":
            next.status = .open
            next.completedAt = nil
        case "todo.delete":
            next.status = .deleted
        case "todo.restore":
            next.status = .open
        case "todo.move":
            if op.has("parent") {
                let parent = op.string("parent").flatMap(lookup)
                next.parentId = op.string("parent")
                next.depth = parent.map { $0.depth + 1 } ?? 0
                next.rootId = parent?.rootId ?? todo.id
            }
            if let list = op.string("list") { next.listId = list }
        case "todo.tag":
            next.tags = withTags(todo.tags, add: op.strings("add") ?? [], remove: op.strings("remove") ?? [])
        case "desk.add":
            next.onDesk = true
        case "desk.remove":
            next.onDesk = false
        case "nudge.set":
            next.hasNudge = true
        default:
            return todo
        }
        return next
    }

    // MARK: - The desk

    /// What identifies a desk item across the server's answer and the queue: a todo by the todo,
    /// a divider by its own id. A queued add has no server id yet, so the todo is the only handle.
    public static func deskKey(_ item: TodoDeskItem) -> String {
        item.kind == .divider ? "divider:\(item.id)" : "todo:\(item.todoId ?? "")"
    }

    private static func indexOfRef(_ items: [TodoDeskItem], _ ref: String) -> Int? {
        items.firstIndex { $0.id == ref || $0.todoId == ref }
    }

    private static func insert(_ item: TodoDeskItem, into items: inout [TodoDeskItem], position: PaiJSONValue?) {
        var at = items.count
        switch position {
        case .string("first"): at = 0
        case .object(let fields):
            if case .string(let ref) = fields["before"], let index = indexOfRef(items, ref) { at = index }
            if case .string(let ref) = fields["after"], let index = indexOfRef(items, ref) { at = index + 1 }
        default: break
        }
        items.insert(item, at: at)
    }

    /// The desk with queued desk ops applied, so an add, a drag or a Clear shows before the
    /// server answers. `todos` are the effective todos, used to know which ones are done for
    /// "clear done". A create with `desk: true` puts its new todo on the desk last.
    public static func applyDeskOps(
        _ items: [TodoDeskItem], changes: [TodosQueuedChange], todos: [String: Todo]
    ) -> [TodoDeskItem] {
        var out = items
        for change in changes {
            for op in change.ops {
                switch op.name {
                case "desk.add", "todo.create":
                    let todoId = op.name == "desk.add" ? op.string("todo") : op.string("id")
                    guard let todoId, op.name == "desk.add" || op.bool("desk") == true,
                        !out.contains(where: { $0.kind == .todo && $0.todoId == todoId })
                    else { break }
                    let item = TodoDeskItem(id: "pending:\(todoId)", kind: .todo, todoId: todoId, title: nil)
                    insert(item, into: &out, position: op.name == "desk.add" ? op.fields["position"] : nil)
                case "desk.divider":
                    guard let id = op.string("id"), let title = op.string("title") else { break }
                    if let existing = out.firstIndex(where: { $0.id == id }) {
                        out[existing].title = title
                    } else {
                        insert(
                            TodoDeskItem(id: id, kind: .divider, todoId: nil, title: title), into: &out,
                            position: op.fields["position"])
                    }
                case "desk.move":
                    guard let ref = op.string("item"), let from = indexOfRef(out, ref) else { break }
                    let moved = out.remove(at: from)
                    insert(moved, into: &out, position: op.fields["position"])
                case "desk.remove":
                    if let ref = op.string("item"), let at = indexOfRef(out, ref) { out.remove(at: at) }
                case "desk.clear":
                    switch op.fields["what"] {
                    case .string("all"):
                        out = []
                    case .string("done"):
                        out = out.filter { $0.kind == .divider || todos[$0.todoId ?? ""]?.status == .open }
                    case .object(let fields):
                        guard case .string(let section) = fields["section"],
                            let start = out.firstIndex(where: { $0.id == section })
                        else { break }
                        var end = start + 1
                        while end < out.count, out[end].kind != .divider { end += 1 }
                        out.removeSubrange(start..<end)
                    default:
                        break
                    }
                default:
                    break
                }
            }
        }
        return out
    }

    // MARK: - The feed

    /// What the feed's events ask of the client.
    public struct EventEffect: Equatable, Sendable {
        /// Todos whose rows are now out of date.
        public var todoIds: [String]
        /// Lists, members, tags, views or preferences changed: read `/me` again.
        public var refreshMe: Bool
    }

    static let todoScopedEntities: Set<String> = [
        "todo", "tag_link", "completion", "link", "attachment", "nudge", "desk_item",
    ]
    static let meEntities: Set<String> = ["list", "member", "tag", "view", "prefs"]

    /// What the feed's events ask of the client. Events carry raw rows, not wire todos, so a todo
    /// is never patched from one: it is marked for a re-read and the answer replaces it.
    public static func effectOfEvents(_ events: [TodoEvent]) -> EventEffect {
        var ids: [String] = []
        var seen = Set<String>()
        var refreshMe = false
        for event in events {
            if meEntities.contains(event.entity) { refreshMe = true }
            if todoScopedEntities.contains(event.entity), let id = event.todoId, seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return EventEffect(todoIds: ids, refreshMe: refreshMe)
    }

    // MARK: - The person's day

    /// The person's day of an instant, as the server counts it (`scope.day_of`): the local date of
    /// `at - rollover` in their zone, so a tick at 02:00 before a 03:30 rollover counts for the day
    /// before. Nil when the zone or the rollover cannot be read.
    public static func dayOf(_ at: Date, timezone: String, rollover: String) -> String? {
        guard let zone = TimeZone(identifier: timezone) else { return nil }
        let parts = rollover.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // On the local wall clock, as Python subtracts a timedelta from an aware datetime.
        let local = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        guard let year = local.year, let month = local.month, let day = local.day, let hour = local.hour,
            let minute = local.minute,
            var date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        else { return nil }
        if hour * 60 + minute < parts[0] * 60 + parts[1] {
            guard let before = calendar.date(byAdding: .day, value: -1, to: date) else { return nil }
            date = before
        }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", result.year ?? 0, result.month ?? 0, result.day ?? 0)
    }
}
