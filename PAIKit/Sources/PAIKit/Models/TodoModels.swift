import Foundation

/// The Todos wire, as `/api/todos` answers it (pai-cloud `docs/api/todos.openapi.json`, generated
/// from `todos/wire.py`). Ids, dates (`YYYY-MM-DD`) and instants stay strings: an instant goes
/// through `IsoTimestamp.date(from:)` where a screen needs it as a `Date`.
///
/// Every closed set of strings decodes an unknown value as `.unrecognized`, so an older build
/// survives a value the server added later. Names carry `Todo`/`Todos` where the web's would
/// collide with SwiftUI (`View`) or read too generally (`Tag`, `Change`).

/// A closed set of wire strings that still decodes a value this build predates.
public protocol TodosWireEnum: Codable, Equatable, Sendable {
    static var knownValues: [String: Self] { get }
    static func unrecognized(_ raw: String) -> Self
    var rawValue: String { get }
}

extension TodosWireEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? Self.unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TodoStatus: TodosWireEnum {
    case open, done, dropped, deleted
    case unrecognized(String)

    public static let knownValues: [String: TodoStatus] = [
        "open": .open, "done": .done, "dropped": .dropped, "deleted": .deleted,
    ]

    public var rawValue: String {
        switch self {
        case .open: "open"
        case .done: "done"
        case .dropped: "dropped"
        case .deleted: "deleted"
        case .unrecognized(let raw): raw
        }
    }
}

public enum TodoHorizon: TodosWireEnum {
    case now, week, soon, whenever
    case unrecognized(String)

    public static let knownValues: [String: TodoHorizon] = [
        "now": .now, "week": .week, "soon": .soon, "whenever": .whenever,
    ]

    public var rawValue: String {
        switch self {
        case .now: "now"
        case .week: "week"
        case .soon: "soon"
        case .whenever: "whenever"
        case .unrecognized(let raw): raw
        }
    }
}

public enum TodoListKind: TodosWireEnum {
    case personal, shared, issues
    case unrecognized(String)

    public static let knownValues: [String: TodoListKind] = [
        "personal": .personal, "shared": .shared, "issues": .issues,
    ]

    public var rawValue: String {
        switch self {
        case .personal: "personal"
        case .shared: "shared"
        case .issues: "issues"
        case .unrecognized(let raw): raw
        }
    }
}

public enum TodoRole: TodosWireEnum {
    case owner, editor, filer, viewer
    case unrecognized(String)

    public static let knownValues: [String: TodoRole] = [
        "owner": .owner, "editor": .editor, "filer": .filer, "viewer": .viewer,
    ]

    public var rawValue: String {
        switch self {
        case .owner: "owner"
        case .editor: "editor"
        case .filer: "filer"
        case .viewer: "viewer"
        case .unrecognized(let raw): raw
        }
    }
}

public enum TodoActorKind: TodosWireEnum {
    case human, agent, automation, `import`, system
    case unrecognized(String)

    public static let knownValues: [String: TodoActorKind] = [
        "human": .human, "agent": .agent, "automation": .automation, "import": .import, "system": .system,
    ]

    public var rawValue: String {
        switch self {
        case .human: "human"
        case .agent: "agent"
        case .automation: "automation"
        case .import: "import"
        case .system: "system"
        case .unrecognized(let raw): raw
        }
    }
}

public enum TodoDeskItemKind: TodosWireEnum {
    case todo, divider
    case unrecognized(String)

    public static let knownValues: [String: TodoDeskItemKind] = ["todo": .todo, "divider": .divider]

    public var rawValue: String {
        switch self {
        case .todo: "todo"
        case .divider: "divider"
        case .unrecognized(let raw): raw
        }
    }
}

// MARK: - Small values

public struct TodoWhen: Codable, Equatable, Sendable {
    public var date: String
    public var time: String?

    public init(date: String, time: String? = nil) {
        self.date = date
        self.time = time
    }
}

public struct TodoDeadline: Codable, Equatable, Sendable {
    public var date: String
    public var leadDays: Int?

    public init(date: String, leadDays: Int? = nil) {
        self.date = date
        self.leadDays = leadDays
    }

    enum CodingKeys: String, CodingKey {
        case date
        case leadDays = "lead_days"
    }
}

/// How a todo comes round again. `on` is `{"weekdays": [1...7]}` or `{"month_day": n | "last"}`.
public struct TodoRepeat: Codable, Equatable, Sendable {
    public var mode: String
    public var every: Int
    public var unit: String
    public var on: PaiJSONValue?
    public var anchorDay: Int?
    public var until: String?
    public var skipMissed: Bool

    enum CodingKeys: String, CodingKey {
        case mode, every, unit, on, until
        case anchorDay = "anchor_day"
        case skipMissed = "skip_missed"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        every = try container.decode(Int.self, forKey: .every)
        unit = try container.decode(String.self, forKey: .unit)
        on = try container.decodeIfPresent(PaiJSONValue.self, forKey: .on)
        anchorDay = try container.decodeIfPresent(Int.self, forKey: .anchorDay)
        until = try container.decodeIfPresent(String.self, forKey: .until)
        skipMissed = try container.decodeIfPresent(Bool.self, forKey: .skipMissed) ?? false
    }
}

public struct TodoLink: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let target: String
    public let label: String?
    public let url: String
}

public struct TodoAttachment: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let contentType: String
    public let size: Int
    public let width: Int?
    public let height: Int?
    public let url: String

    enum CodingKeys: String, CodingKey {
        case id, name, size, width, height, url
        case contentType = "content_type"
    }
}

public struct TodoChecklist: Codable, Equatable, Sendable {
    public let done: Int
    public let total: Int
}

public struct TodoCreated: Codable, Equatable, Sendable {
    public var at: String
    /// `user:<uuid>`, `ns:<slug>` or `key:<key id>`.
    public var by: String
    public var kind: TodoActorKind
    public var label: String
    public var source: String
    public var sessionId: String?

    enum CodingKeys: String, CodingKey {
        case at, by, kind, label, source
        case sessionId = "session_id"
    }
}

// MARK: - Objects

/// A todo as one caller sees it.
public struct Todo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Nil until the server acknowledged the create.
    public var number: Int?
    public var ref: String?
    public var listId: String
    public var parentId: String?
    public var rootId: String
    public var depth: Int
    public var rank: String
    public var title: String
    public var bodyPreview: String
    /// Only when asked for; nil otherwise.
    public var body: String?
    public var bodyHash: String
    public var status: TodoStatus
    public var inbox: Bool
    public var horizon: TodoHorizon
    public var when: TodoWhen?
    public var someday: Bool
    public var deadline: TodoDeadline?
    public var `repeat`: TodoRepeat?
    public var tags: [String]
    public var inheritedTags: [String]
    public var links: [TodoLink]
    public var attachments: [TodoAttachment]
    public var childrenOpen: Int
    public var childrenTotal: Int
    public var checklist: TodoChecklist?
    public var completedAt: String?
    public var completedCount: Int
    public var lastDoneAt: String?
    public var key: String?
    public var created: TodoCreated
    public var updatedAt: String
    public var updatedSeq: Int
    public var version: Int
    public var asleep: Bool
    public var inBand: Bool
    public var onDesk: Bool
    public var hasNudge: Bool
    /// A non-matching ancestor shown to place matches under it.
    public var context: Bool?
    /// In a `fold` answer: matching descendants living under this row.
    public var foldedIds: [String]?

    enum CodingKeys: String, CodingKey {
        case id, number, ref, depth, rank, title, body, status, inbox, horizon, when, someday, deadline
        case `repeat`, tags, links, attachments, checklist, key, created, version, asleep, context
        case listId = "list_id"
        case parentId = "parent_id"
        case rootId = "root_id"
        case bodyPreview = "body_preview"
        case bodyHash = "body_hash"
        case inheritedTags = "inherited_tags"
        case childrenOpen = "children_open"
        case childrenTotal = "children_total"
        case completedAt = "completed_at"
        case completedCount = "completed_count"
        case lastDoneAt = "last_done_at"
        case updatedAt = "updated_at"
        case updatedSeq = "updated_seq"
        case inBand = "in_band"
        case onDesk = "on_desk"
        case hasNudge = "has_nudge"
        case foldedIds = "folded_ids"
    }
}

public struct TodoDeskItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: TodoDeskItemKind
    public var todoId: String?
    public var title: String?
    public var rank: String
    public var addedAt: String
    public var addedDay: String

    public init(
        id: String, kind: TodoDeskItemKind, todoId: String?, title: String?, rank: String = "",
        addedAt: String = "", addedDay: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.todoId = todoId
        self.title = title
        self.rank = rank
        self.addedAt = addedAt
        self.addedDay = addedDay
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, rank
        case todoId = "todo_id"
        case addedAt = "added_at"
        case addedDay = "added_day"
    }
}

public struct TodoMember: Codable, Equatable, Sendable {
    public let principal: String
    public let role: TodoRole
    public let displayName: String

    enum CodingKeys: String, CodingKey {
        case principal, role
        case displayName = "display_name"
    }
}

public struct TodoListCounts: Codable, Equatable, Sendable {
    public let open: Int
}

/// A list, with the caller's own role in it.
public struct TodoList: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: TodoListKind
    public let layout: String
    public let icon: String?
    public let color: String?
    public let locked: Bool
    public let archived: Bool
    public let role: TodoRole
    public let members: [TodoMember]
    public let counts: TodoListCounts
}

public struct TodoTag: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let listId: String
    public let name: String
    public let color: String?
    public let icon: String?
    public let quiet: Bool
    public let openCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, color, icon, quiet
        case listId = "list_id"
        case openCount = "open_count"
    }
}

/// What a todo created while a view is open starts with.
public struct TodoViewDefaults: Codable, Equatable, Sendable {
    public let tags: [String]?
    public let horizon: TodoHorizon?
    public let list: String?
    public let when: String?
    public let desk: Bool?
    public let parent: String?
}

/// A saved view: a query and how to show it. (The web's `View`.)
public struct TodoView: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let icon: String?
    public let builtin: String?
    public let layout: String
    public let query: String
    public let groupBy: String
    public let sort: String
    public let tree: String
    public let display: PaiJSONValue
    public let pinned: Bool
    public let rank: String
    public let defaults: TodoViewDefaults

    enum CodingKeys: String, CodingKey {
        case id, name, icon, builtin, layout, query, sort, tree, display, pinned, rank, defaults
        case groupBy = "group_by"
    }
}

public struct TodoSavedScope: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let query: String
}

public struct TodoPrefs: Codable, Equatable, Sendable {
    public let timezone: String
    public let dayRollover: String
    public let deadlineLeadDays: Int
    public let defaultListId: String?
    public let scopes: [TodoSavedScope]
    public let activeScope: String?
    public let seenSeq: Int

    enum CodingKeys: String, CodingKey {
        case timezone, scopes
        case dayRollover = "day_rollover"
        case deadlineLeadDays = "deadline_lead_days"
        case defaultListId = "default_list_id"
        case activeScope = "active_scope"
        case seenSeq = "seen_seq"
    }
}

public struct TodoActor: Codable, Equatable, Sendable {
    public let principal: String
    public let kind: TodoActorKind
    public let label: String
}

/// One entity a change created, updated or deleted. Events carry raw rows, never wire todos:
/// they say what to read again, nothing is patched from them.
public struct TodoEvent: Codable, Equatable, Sendable {
    public let seq: Int
    public let changeId: String
    public let entity: String
    public let entityId: String
    public let todoId: String?
    public let listId: String?
    public let op: String
    public let before: PaiJSONValue?
    public let after: PaiJSONValue?

    enum CodingKeys: String, CodingKey {
        case seq, entity, op, before, after
        case changeId = "change_id"
        case entityId = "entity_id"
        case todoId = "todo_id"
        case listId = "list_id"
    }
}

/// One operation, one Undo. (The web's `Change`.)
public struct TodoChange: Codable, Equatable, Sendable {
    public let id: String
    public let seqFirst: Int
    public let seqLast: Int
    public let actor: TodoActor
    public let source: String
    public let sessionId: String?
    public let summary: String
    public let opCount: Int
    public let undoOf: String?
    public let undoneBy: String?
    public let createdAt: String
    public let events: [TodoEvent]?

    enum CodingKeys: String, CodingKey {
        case id, actor, source, summary, events
        case seqFirst = "seq_first"
        case seqLast = "seq_last"
        case sessionId = "session_id"
        case opCount = "op_count"
        case undoOf = "undo_of"
        case undoneBy = "undone_by"
        case createdAt = "created_at"
    }
}

// MARK: - Answers

/// `GET /me`: everything a client boots from; `seq` is the feed's cursor at read time.
public struct TodosMeAnswer: Codable, Equatable, Sendable {
    public let principal: String
    public let userId: String?
    public let displayName: String
    public let actorKind: TodoActorKind
    public let lists: [TodoList]
    /// Nil for a namespace's agent, which has no person.
    public let prefs: TodoPrefs?
    public let views: [TodoView]
    public let tags: [TodoTag]
    public let seq: Int

    enum CodingKeys: String, CodingKey {
        case principal, lists, prefs, views, tags, seq
        case userId = "user_id"
        case displayName = "display_name"
        case actorKind = "actor_kind"
    }
}

/// `GET /today`: the desk in its hand order, its todos by id, and the "due today" strip.
public struct TodosTodayAnswer: Codable, Equatable, Sendable {
    public let desk: [TodoDeskItem]
    public let todos: [String: Todo]
    public let due: [Todo]
    public let seq: Int
    public let day: String
}

public struct TodoQueryGroup: Codable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let ids: [String]
}

public struct TodoExplain: Codable, Equatable, Sendable {
    public let normalized: String
    public let defaults: [String]
}

public struct TodosQueryAnswer: Codable, Equatable, Sendable {
    public let todos: [Todo]
    public let groups: [TodoQueryGroup]
    public let total: Int
    public let nextCursor: String?
    public let seq: Int
    public let explain: TodoExplain

    enum CodingKeys: String, CodingKey {
        case todos, groups, total, seq, explain
        case nextCursor = "next_cursor"
    }
}

/// `POST /query`. `scope` is always sent: `null` means no saved scope, which an absent key
/// would not (absent is "the caller's active scope").
public struct TodosQueryRequest: Encodable, Equatable, Sendable {
    public var q: String
    public var scope: String?
    public var group: String?
    public var tree: String?
    public var limit: Int
    public var cursor: String?

    public init(
        q: String, scope: String? = nil, group: String? = nil, tree: String? = nil, limit: Int = 500,
        cursor: String? = nil
    ) {
        self.q = q
        self.scope = scope
        self.group = group
        self.tree = tree
        self.limit = limit
        self.cursor = cursor
    }

    enum CodingKeys: String, CodingKey { case q, scope, group, tree, limit, cursor }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(q, forKey: .q)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encodeIfPresent(tree, forKey: .tree)
        try container.encode(limit, forKey: .limit)
        try container.encodeIfPresent(cursor, forKey: .cursor)
    }
}

public struct TodosEventsAnswer: Codable, Equatable, Sendable {
    public let events: [TodoEvent]
    public let head: Int
    /// The cursor is too old or the caller's memberships changed: boot again from `GET /me`.
    public let reset: Bool
}

/// A change made to a todo after the version the caller held.
public struct TodoConflictEvent: Codable, Equatable, Sendable {
    public let seq: Int
    public let actorLabel: String
    public let source: String
    public let changed: [String]

    enum CodingKeys: String, CodingKey {
        case seq, source, changed
        case actorLabel = "actor_label"
    }
}

/// The body of every non-2xx Todos answer: `error` is the code, `message` a sentence, and which
/// detail fields are present depends on the code.
public struct TodosErrorBody: Codable, Equatable, Sendable {
    public let error: String
    public let message: String
    public let field: String?
    public let listId: String?
    public let needs: TodoRole?
    public let ref: String?
    public let todo: String?
    /// `conflict`: the todo as it is now.
    public let current: Todo?
    /// `conflict`: who changed it since, oldest first.
    public let since: [TodoConflictEvent]?
    public let index: Int?
    public let op: String?
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case error, message, field, needs, ref, todo, current, since, index, op, reason
        case listId = "list_id"
    }
}

public struct TodoOpResult: Codable, Equatable, Sendable {
    public let index: Int
    public let ok: Bool
    public let ref: String?
    public let id: String?
    public let error: TodosErrorBody?
}

/// `POST /apply`'s answer. `replayed` says the change id was already applied and this is that
/// change's answer again.
public struct TodosApplyResult: Codable, Equatable, Sendable {
    /// Nil for a dry run, or when nothing applied.
    public let change: TodoChange?
    public let applied: Int
    public let of: Int
    public let results: [TodoOpResult]
    /// Every todo touched, as it is now.
    public let todos: [Todo]
    public let events: [TodoEvent]
    public let replayed: Bool
}

/// A span of the capture line the parser read as a field; `start` and `end` are UTF-16 code
/// units.
public struct TodoParseToken: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let kind: String
    public let value: PaiJSONValue
    /// How a chip names it ("Fri 27 Nov 17:00", "#home").
    public let display: String
}

public struct TodoParseFields: Codable, Equatable, Sendable {
    public let tags: [String]
    public let horizon: TodoHorizon?
    public let when: TodoWhen?
    public let deadline: TodoDeadline?
    public let `repeat`: TodoRepeat?
    public let parent: String?
    public let list: String?
    public let desk: Bool
    public let nudges: [PaiJSONValue]
}

/// Something the parser read that cannot be used, such as a `/List` the caller has no list of.
public struct TodoParseIssue: Codable, Equatable, Sendable {
    public let position: Int
    public let length: Int
    public let message: String
    public let suggestion: String?
}

/// `POST /parse`: the capture parser's reading. It never refuses: what it cannot read stays in
/// the title. `createOp` is the `todo.create` it implies, with the list it named resolved.
public struct TodosParseAnswer: Codable, Equatable, Sendable {
    public let title: String
    public let fields: TodoParseFields
    public let tokens: [TodoParseToken]
    public let createOp: TodoOp
    public let issues: [TodoParseIssue]

    enum CodingKeys: String, CodingKey {
        case title, fields, tokens, issues
        case createOp = "create_op"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        fields = try container.decode(TodoParseFields.self, forKey: .fields)
        tokens = try container.decode([TodoParseToken].self, forKey: .tokens)
        createOp = try container.decode(TodoOp.self, forKey: .createOp)
        issues = try container.decodeIfPresent([TodoParseIssue].self, forKey: .issues) ?? []
    }
}
