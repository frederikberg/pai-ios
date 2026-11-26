import Foundation

/// One typed operation of a change (`todo.create`, `desk.add`, ...), held as the JSON object the
/// wire carries.
///
/// The object is the op: the constructors below write the fields this app sends, an op the
/// server built (the parser's `create_op`) keeps every field it named, and an op read back from
/// the outbox file is sent byte for byte as it was queued, whatever this build knows about its
/// fields. The accessors read only what the optimistic layer needs.
public struct TodoOp: Codable, Equatable, Sendable {
    public private(set) var fields: [String: PaiJSONValue]

    public init(fields: [String: PaiJSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: PaiJSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }

    /// The op's name: `todo.create`, `desk.remove`, ...
    public var name: String { string("op") ?? "" }

    public func string(_ key: String) -> String? {
        if case .string(let value) = fields[key] { return value }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let value) = fields[key] { return value }
        return nil
    }

    public func strings(_ key: String) -> [String]? {
        guard case .array(let values) = fields[key] else { return nil }
        return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }

    /// Whether the op names `key` at all, `null` included: `todo.update`'s `set` and
    /// `todo.move`'s `parent` mean "clear" by an explicit null and "keep" by absence.
    public func has(_ key: String) -> Bool { fields[key] != nil }

    public func object(_ key: String) -> TodoOp? {
        if case .object(let value) = fields[key] { return TodoOp(fields: value) }
        return nil
    }

    /// The value at `key` decoded as `T`, or nil when absent, null or of another shape.
    public func decoded<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let value = fields[key], value != .null, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The same op with `key` set to `value`.
    public func setting(_ key: String, _ value: PaiJSONValue) -> TodoOp {
        var copy = self
        copy.fields[key] = value
        return copy
    }

    /// The same op without the keys whose value says nothing: null, an empty list, or a `desk`
    /// of false. The parser's `create_op` names every field; sent like that, a null `inbox`
    /// would still be read as "not given", but the op in the log should hold what was meant.
    /// The CLI's capture sends the parser's op the same way.
    public func withoutEmptyFields() -> TodoOp {
        TodoOp(
            fields: fields.filter { key, value in
                switch value {
                case .null: return false
                case .array(let items): return !items.isEmpty
                case .bool(false): return key != "desk"
                default: return true
                }
            })
    }
}

/// Where a row goes in a hand order.
public enum TodoPosition: Hashable, Sendable {
    case first, last
    case before(String)
    case after(String)

    var json: PaiJSONValue {
        switch self {
        case .first: .string("first")
        case .last: .string("last")
        case .before(let ref): .object(["before": .string(ref)])
        case .after(let ref): .object(["after": .string(ref)])
        }
    }
}

extension TodoOp {
    /// `todo.create` of a plain title. `id` is made by the client, so later ops can name the todo
    /// before the server has answered.
    public static func create(
        id: String, title: String, list: String? = nil, parent: String? = nil, tags: [String] = [],
        desk: Bool = false, links: [TodoLinkSpec] = []
    ) -> TodoOp {
        var fields: [String: PaiJSONValue] = ["op": .string("todo.create"), "id": .string(id), "title": .string(title)]
        if let list { fields["list"] = .string(list) }
        if let parent { fields["parent"] = .string(parent) }
        if !tags.isEmpty { fields["tags"] = .array(tags.map(PaiJSONValue.string)) }
        if desk { fields["desk"] = .bool(true) }
        if !links.isEmpty { fields["links"] = .array(links.map(\.json)) }
        return TodoOp(fields: fields)
    }

    /// Ticks a todo and its open descendants; a repeating one moves on to its next occurrence.
    public static func complete(todo: String, dropped: Bool = false) -> TodoOp {
        TodoOp(fields: [
            "op": .string("todo.complete"), "todo": .string(todo), "as": .string(dropped ? "dropped" : "done"),
        ])
    }

    public static func reopen(todo: String) -> TodoOp {
        TodoOp(fields: ["op": .string("todo.reopen"), "todo": .string(todo)])
    }

    /// Puts a todo on the caller's desk; idempotent on the server.
    public static func deskAdd(todo: String, position: TodoPosition? = nil) -> TodoOp {
        var fields: [String: PaiJSONValue] = ["op": .string("desk.add"), "todo": .string(todo)]
        if let position { fields["position"] = position.json }
        return TodoOp(fields: fields)
    }

    /// Takes an item off the desk: a desk item's id, or the ref of a todo on it.
    public static func deskRemove(item: String) -> TodoOp {
        TodoOp(fields: ["op": .string("desk.remove"), "item": .string(item)])
    }
}

/// A link a todo is created with.
public struct TodoLinkSpec: Equatable, Sendable, Codable {
    public let kind: String
    public let target: String
    public let label: String?

    public init(kind: String, target: String, label: String? = nil) {
        self.kind = kind
        self.target = target
        self.label = label
    }

    /// A web address.
    public static func url(_ target: String, label: String? = nil) -> TodoLinkSpec {
        TodoLinkSpec(kind: "url", target: target, label: label)
    }

    var json: PaiJSONValue {
        var fields: [String: PaiJSONValue] = ["kind": .string(kind), "target": .string(target)]
        if let label, !label.isEmpty { fields["label"] = .string(String(label.prefix(200))) }
        return .object(fields)
    }
}

/// `POST /apply`: one change, one Undo. The same JSON is the web outbox entry and this app's
/// outbox record; replaying the same `change_id` answers the first answer again.
public struct TodosChangeRequest: Encodable, Equatable, Sendable {
    public let changeId: String
    public let summary: String?
    public let ops: [TodoOp]

    public init(changeId: String, summary: String?, ops: [TodoOp]) {
        self.changeId = changeId
        self.summary = summary
        self.ops = ops
    }

    enum CodingKeys: String, CodingKey {
        case summary, ops, atomic
        case changeId = "change_id"
        case dryRun = "dry_run"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(changeId, forKey: .changeId)
        try container.encode(summary, forKey: .summary)
        try container.encode(true, forKey: .atomic)
        try container.encode(false, forKey: .dryRun)
        try container.encode(ops, forKey: .ops)
    }
}
