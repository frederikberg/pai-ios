import Foundation

/// How long a title may be and where a longer one is cut: the server's rule (pai-cloud
/// `todos/titles.py`) by the same steps. The server does the cutting, at create and at every
/// later title change, and puts the words after the cut on top of the description; the phone sends
/// what was typed and only shows, while typing, which words will move.
public enum TodoTitles {
    /// The longest title a todo keeps, counted as the server counts it (Unicode scalars).
    public static let limit = 500

    /// `text` as the title that stays and the words that move to the description.
    public static func split(_ text: String) -> (title: String, rest: String) {
        let scalars = Array(text.unicodeScalars)
        guard let cut = cutIndex(scalars) else { return (text, "") }
        return (string(scalars[..<cut]).trimmingTrailingWhitespace(), string(scalars[cut...]).trimmed())
    }

    /// Where a title longer than the limit is cut: the last whitespace inside the limit, or the
    /// limit itself inside a first word longer than that. Nil when it fits.
    static func cutIndex(_ scalars: [Unicode.Scalar]) -> Int? {
        guard scalars.count > limit else { return nil }
        if scalars[limit].properties.isWhitespace { return limit }
        guard let space = scalars[..<limit].lastIndex(where: { $0.properties.isWhitespace }), space > 0,
            scalars[..<space].contains(where: { !$0.properties.isWhitespace })
        else { return limit }
        return space
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// The parts of a typed line that will move to the description, as UTF-16 ranges of the line.
    /// `tokens` are the words the parser reads as fields (a day, a tag): they are no part of the
    /// title, so they neither count towards the limit nor move.
    public static func overflow(of text: String, tokens: [TodoParseToken] = []) -> [Range<Int>] {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit else { return [] }
        var isField = [Bool](repeating: false, count: scalars.count)
        for token in tokens where token.start < token.end {
            for index in max(0, token.start)..<min(scalars.count, token.end) { isField[index] = true }
        }
        let kept = scalars.indices.filter { !isField[$0] }
        guard let cut = cutIndex(kept.map { scalars[$0] }) else { return [] }
        let from = kept[cut]
        var ranges: [Range<Int>] = []
        var offset = 0
        for (index, scalar) in scalars.enumerated() {
            let width = scalar.utf16.count
            if index >= from, !isField[index] {
                if let last = ranges.last, last.upperBound == offset {
                    ranges[ranges.count - 1] = last.lowerBound..<(offset + width)
                } else {
                    ranges.append(offset..<(offset + width))
                }
            }
            offset += width
        }
        return ranges
    }
}

extension String {
    fileprivate func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }

    fileprivate func trimmingTrailingWhitespace() -> String {
        var scalars = Array(unicodeScalars)
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

/// What the pickers chose for a todo not made yet, the web's `AddDraft` (`quickadd/draft.ts`): a
/// chosen field replaces what the line typed and what the view would give; "no day" and "no
/// deadline" are choices too. Tags add to the line's and the view's.
public struct TodoAddDraft: Codable, Equatable, Sendable {
    public var when: TodoWhen?
    /// "No day" was chosen: the view's day stays off this todo.
    public var noDay = false
    public var someday: Bool?
    /// The repeat as the JSON the wire carries.
    public var repeatRule: [String: PaiJSONValue]?
    public var deadline: TodoDeadline?
    public var noDeadline = false
    public var horizon: TodoHorizon?
    public var list: String?
    public var tags: [String] = []
    /// Nudge specs (`{id, at}` or `{id, before}`), as a `todo.create` carries them.
    public var nudges: [PaiJSONValue] = []
    public var desk: Bool?

    public init() {}

    public var isEmpty: Bool { self == TodoAddDraft() }

    enum CodingKeys: String, CodingKey {
        case when, someday, deadline, horizon, list, tags, nudges, desk
        case noDay = "no_day"
        case noDeadline = "no_deadline"
        case repeatRule = "repeat"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        when = try container.decodeIfPresent(TodoWhen.self, forKey: .when)
        noDay = try container.decodeIfPresent(Bool.self, forKey: .noDay) ?? false
        someday = try container.decodeIfPresent(Bool.self, forKey: .someday)
        repeatRule = try container.decodeIfPresent([String: PaiJSONValue].self, forKey: .repeatRule)
        deadline = try container.decodeIfPresent(TodoDeadline.self, forKey: .deadline)
        noDeadline = try container.decodeIfPresent(Bool.self, forKey: .noDeadline) ?? false
        horizon = try container.decodeIfPresent(TodoHorizon.self, forKey: .horizon)
        list = try container.decodeIfPresent(String.self, forKey: .list)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        nudges = try container.decodeIfPresent([PaiJSONValue].self, forKey: .nudges) ?? []
        desk = try container.decodeIfPresent(Bool.self, forKey: .desk)
    }

    /// The draft without the pick a chip stands for (`when`, `deadline`, `repeat`, `horizon`,
    /// `list`, `desk`, `tag:<name>`, `nudge:<id>`).
    public func without(_ pick: String) -> TodoAddDraft {
        var next = self
        switch pick {
        case "when":
            next.when = nil
            next.noDay = false
            next.someday = nil
        case "deadline":
            next.deadline = nil
            next.noDeadline = false
        case "repeat": next.repeatRule = nil
        case "horizon": next.horizon = nil
        case "list": next.list = nil
        case "desk": next.desk = nil
        default:
            if pick.hasPrefix("tag:") {
                let name = pick.dropFirst(4).lowercased()
                next.tags.removeAll { $0.lowercased() == name }
            } else if pick.hasPrefix("nudge:") {
                let id = String(pick.dropFirst(6))
                next.nudges.removeAll { $0.objectValue?["id"]?.stringValue == id }
            }
        }
        return next
    }
}

extension PaiJSONValue {
    fileprivate var objectValue: [String: PaiJSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}

extension TodoCreate {
    /// The `todo.create` a sheet sends: the line's op (its typed fields over the view's defaults)
    /// with the pickers' choices laid over it, the web's `withDraft`.
    public static func withDraft(_ op: TodoOp, _ draft: TodoAddDraft) -> TodoOp {
        var out = op
        if let when = draft.when {
            out = out.setting(
                "when", .object(["date": .string(when.date), "time": when.time.map(PaiJSONValue.string) ?? .null]))
            out = out.setting("someday", .bool(false))
        } else if draft.noDay {
            out = out.setting("when", .null)
        }
        if draft.when == nil, let someday = draft.someday { out = out.setting("someday", .bool(someday)) }
        if let rule = draft.repeatRule { out = out.setting("repeat", .object(rule)) }
        if let deadline = draft.deadline {
            out = out.setting(
                "deadline",
                .object([
                    "date": .string(deadline.date),
                    "lead_days": deadline.leadDays.map { .number(Decimal($0)) } ?? .null,
                ]))
        } else if draft.noDeadline {
            out = out.setting("deadline", .null)
        }
        if let horizon = draft.horizon { out = out.setting("horizon", .string(horizon.rawValue)) }
        if let list = draft.list { out = out.setting("list", .string(list)) }
        if !draft.tags.isEmpty {
            var tags = out.strings("tags") ?? []
            for tag in draft.tags where !tags.contains(where: { $0.lowercased() == tag.lowercased() }) {
                tags.append(tag)
            }
            out = out.setting("tags", .array(tags.map(PaiJSONValue.string)))
        }
        if !draft.nudges.isEmpty {
            var nudges: [PaiJSONValue] = []
            if case .array(let typed) = out.fields["nudges"] { nudges = typed }
            out = out.setting("nudges", .array(nudges + draft.nudges))
        }
        if let desk = draft.desk { out = out.setting("desk", .bool(desk)) }
        return out
    }
}

/// The fields a todo has, or a new one will get: what a picker shows as chosen, whichever of the
/// two it is opened for.
public struct TodoEntryValues: Equatable, Sendable {
    public var when: TodoWhen?
    public var someday = false
    public var repeatRule: [String: PaiJSONValue]?
    public var deadline: TodoDeadline?
    /// Nil on a new todo nobody gave one: the server makes it Whenever.
    public var horizon: TodoHorizon?
    public var listId: String?
    public var tags: [String] = []
    public var nudges: [TodoNudge] = []
    public var onDesk = false

    public init() {}

    /// An existing todo's fields, with the caller's nudges on it.
    public init(todo: Todo, nudges: [TodoNudge]) {
        when = todo.when
        someday = todo.someday
        repeatRule = todo.repeat.map(TodoFieldOps.repeatJSON)
        deadline = todo.deadline
        horizon = todo.horizon
        listId = todo.listId
        tags = todo.tags
        self.nudges = nudges
        onDesk = todo.onDesk
    }

    /// What a `todo.create` will make.
    public init(create op: TodoOp) {
        when = op.decoded("when", as: TodoWhen.self)
        someday = op.bool("someday") ?? false
        if case .object(let rule) = op.fields["repeat"] { repeatRule = rule }
        deadline = op.decoded("deadline", as: TodoDeadline.self)
        horizon = op.string("horizon").map { TodoHorizon.knownValues[$0] ?? .unrecognized($0) }
        listId = op.string("list")
        tags = op.strings("tags") ?? []
        onDesk = op.bool("desk") ?? false
        if case .array(let specs) = op.fields["nudges"] {
            let sets = specs.compactMap { spec -> TodoOp? in
                guard case .object(var fields) = spec else { return nil }
                fields["op"] = .string("nudge.set")
                fields["todo"] = .string(Self.newTodo)
                return TodoOp(fields: fields)
            }
            nudges = TodoWords.overlayNudges([], ops: sets, todoId: Self.newTodo)
        }
    }

    private static let newTodo = "new"
}

extension TodoFieldOps {
    /// A nudge as a new todo carries it: `nudge.set`'s own fields without the op and the todo.
    public static func nudgeSpec(_ choice: NudgeChoice, id: String) -> PaiJSONValue {
        var fields = nudgeSet("", choice, id: id).fields
        fields["op"] = nil
        fields["todo"] = nil
        return .object(fields)
    }
}

extension TodoAddChip {
    /// Every chip of a sheet for a new todo: the view's defaults still standing (dashed, a tap
    /// leaves one off), what the line typed, and what the pickers chose (`pickKey` set, a tap
    /// takes the choice back). A picked field replaces the typed and the default chip of its
    /// kind; tags add up.
    public static func all(
        place: TodoCreatePlace, dismissed: Set<String>, answer: TodosParseAnswer?, draft: TodoAddDraft, today: String,
        listName: (String) -> String?
    ) -> [TodoAddChip] {
        let picked = Self.picked(draft, today: today, listName: listName)
        // "No date" is a choice about the day, so it stands in for the day's chip.
        var replaced = Set(picked.map(\.kind).filter { $0 != "tag" && $0 != "nudge" })
        if replaced.contains("clear") { replaced.insert("when") }
        if replaced.contains("when") { replaced.insert("clear") }
        let gone = TodoCreate.cleared(dismissed, answer: answer)
        let defaults = Self.defaults(place.defaults, dismissed: gone, typed: answer, listName: listName)
            .filter { !replaced.contains($0.kind) }
        let typed = Self.read(answer, today: today).filter { !replaced.contains($0.kind) }
        return defaults + typed + picked
    }

    /// The chips of what the pickers chose.
    public static func picked(_ draft: TodoAddDraft, today: String, listName: (String) -> String?) -> [TodoAddChip] {
        var chips: [TodoAddChip] = []
        if let when = draft.when {
            let label = TodoDates.relativeDay(when.date, today: today) + (when.time.map { " \($0.prefix(5))" } ?? "")
            chips.append(TodoAddChip(key: "pick:when", kind: "when", label: label, pickKey: "when"))
        } else if draft.noDay {
            chips.append(TodoAddChip(key: "pick:when", kind: "clear", label: "No date", pickKey: "when"))
        } else if draft.someday == true {
            chips.append(TodoAddChip(key: "pick:when", kind: "when", label: "Someday", pickKey: "when"))
        }
        if let deadline = draft.deadline {
            chips.append(
                TodoAddChip(
                    key: "pick:deadline", kind: "deadline",
                    label: "Deadline \(TodoDates.relativeDay(deadline.date, today: today))", pickKey: "deadline"))
        }
        if let rule = draft.repeatRule {
            chips.append(
                TodoAddChip(key: "pick:repeat", kind: "repeat", label: TodoWords.repeatRule(rule), pickKey: "repeat"))
        }
        if let horizon = draft.horizon {
            let mark = TodoHorizonMark.of(horizon)
            chips.append(
                TodoAddChip(
                    key: "pick:horizon", kind: "horizon", label: mark.label, color: mark.color, pickKey: "horizon")
            )
        }
        for tag in draft.tags {
            chips.append(TodoAddChip(key: "pick:tag:\(tag)", kind: "tag", label: tag, pickKey: "tag:\(tag)"))
        }
        if let list = draft.list {
            chips.append(TodoAddChip(key: "pick:list", kind: "list", label: listName(list) ?? "List", pickKey: "list"))
        }
        if draft.desk == true {
            chips.append(TodoAddChip(key: "pick:desk", kind: "desk", label: "Desk", pickKey: "desk"))
        }
        for nudge in TodoEntryValues(create: TodoOp(fields: ["nudges": .array(draft.nudges)])).nudges {
            chips.append(
                TodoAddChip(
                    key: "pick:nudge:\(nudge.id)", kind: "nudge", label: TodoWords.nudgeShort(nudge),
                    pickKey: "nudge:\(nudge.id)"))
        }
        return chips
    }

    /// The chips that say what an existing todo's fields hold, in the block on top of its screen.
    public static func fields(_ values: TodoEntryValues, today: String, listName: String?) -> [TodoAddChip] {
        var chips: [TodoAddChip] = []
        if let when = values.when {
            let label = TodoDates.relativeDay(when.date, today: today) + (when.time.map { " \($0.prefix(5))" } ?? "")
            chips.append(TodoAddChip(key: "when", kind: "when", label: label))
        } else if values.someday {
            chips.append(TodoAddChip(key: "when", kind: "when", label: "Someday"))
        }
        if let deadline = values.deadline {
            chips.append(
                TodoAddChip(
                    key: "deadline", kind: "deadline",
                    label: "Deadline \(TodoDates.relativeDay(deadline.date, today: today))"))
        }
        if let rule = values.repeatRule {
            var shown = rule
            shown["until"] = nil
            chips.append(TodoAddChip(key: "repeat", kind: "repeat", label: TodoWords.repeatRule(shown)))
        }
        if let horizon = values.horizon {
            let mark = TodoHorizonMark.of(horizon)
            chips.append(TodoAddChip(key: "horizon", kind: "horizon", label: mark.label, color: mark.color))
        }
        for tag in values.tags { chips.append(TodoAddChip(key: "tag:\(tag)", kind: "tag", label: tag)) }
        if !values.nudges.isEmpty {
            chips.append(TodoAddChip(key: "nudges", kind: "nudge", label: String(values.nudges.count)))
        }
        if let listName { chips.append(TodoAddChip(key: "list", kind: "list", label: listName)) }
        if values.onDesk { chips.append(TodoAddChip(key: "desk", kind: "desk", label: "Desk")) }
        return chips
    }
}

/// What a sheet for a new todo holds while it is open: the line, the description, what the
/// pickers chose and the view's defaults left off.
public struct TodoEntryDraft: Codable, Equatable, Sendable {
    public var text = ""
    public var description = ""
    public var picks = TodoAddDraft()
    public var dismissed: [String] = []

    public init() {}

    /// Nothing typed and nothing chosen: there is nothing to keep.
    public var isEmpty: Bool { !holdsWords && picks.isEmpty && dismissed.isEmpty }

    /// Words were typed, into the line or the description: closing the sheet asks first.
    public var holdsWords: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The drafts of the sheets for a new todo, kept on the device while they hold anything, so an
/// app that is killed, a crash or an outage never takes half-typed words with it (the web's
/// `quickadd/lineDraft.ts`). One entry per sheet: the page's add sheet, and one per parent for its
/// subtask sheet. An entry goes once its todo is sent or the person discards it.
@MainActor
public final class TodoEntryDrafts {
    private let storage: (any SettingsKeyValueStore)?
    private var held: [String: TodoEntryDraft] = [:]

    /// The add sheet's entry, whichever page opened it.
    public static let pageKey = "page"

    public static func subtaskKey(parent: String) -> String { "sub:\(parent)" }

    static func storageKey(_ key: String) -> String { "todos.entryDraft.\(key)" }

    /// `storage` nil keeps nothing between launches (tests, fixture runs).
    public init(storage: (any SettingsKeyValueStore)?) {
        self.storage = storage
    }

    public func draft(for key: String) -> TodoEntryDraft {
        if let draft = held[key] { return draft }
        let stored: TodoEntryDraft? = storage?.value(forKey: Self.storageKey(key))
        return stored ?? TodoEntryDraft()
    }

    /// Keeps the draft; an empty one removes the entry.
    public func keep(_ draft: TodoEntryDraft, for key: String) {
        guard !draft.isEmpty else {
            discard(key)
            return
        }
        held[key] = draft
        storage?.setValue(draft, forKey: Self.storageKey(key))
    }

    public func discard(_ key: String) {
        held[key] = nil
        storage?.setData(nil, forKey: Self.storageKey(key))
    }
}

/// Where "Add here" under a section of the desk puts a new todo.
public enum TodoDeskSections {
    /// The desk split at its dividers: the cards before the first one (`divider` nil), then each
    /// divider with the cards under it.
    public static func sections(_ desk: [TodoDeskItem]) -> [(divider: TodoDeskItem?, cards: [TodoDeskItem])] {
        var out: [(divider: TodoDeskItem?, cards: [TodoDeskItem])] = [(nil, [])]
        for item in desk {
            if item.kind == .divider {
                out.append((item, []))
            } else {
                out[out.count - 1].cards.append(item)
            }
        }
        return out
    }

    /// The end of a section: after its last card, after the divider itself when it has none, and
    /// first on the desk for an empty top.
    public static func end(of dividerId: String?, in desk: [TodoDeskItem]) -> TodoPosition {
        guard let section = sections(desk).first(where: { $0.divider?.id == dividerId }) else { return .last }
        if let last = section.cards.last { return .after(TodoDeskArrange.ref(last)) }
        if let divider = section.divider { return .after(divider.id) }
        return .first
    }
}

/// A file on its way to a todo: the hash its bytes are stored under and the name it keeps.
public enum TodoBlobs {
    public static func sha256Hex(_ data: Data) -> String {
        Sha256.digest(Array(data)).map { String(format: "%02x", $0) }.joined()
    }

    /// A name the server takes: one line, at most 255 characters, never empty.
    static func name(_ name: String) -> String {
        let line = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "file" : String(line.prefix(255))
    }
}

extension TodosErrorBody {
    /// A refusal the phone itself states, in the server's shape.
    static func plain(_ error: String, _ message: String) -> TodosErrorBody {
        TodosErrorBody(
            error: error, message: message, field: nil, listId: nil, needs: nil, ref: nil, todo: nil, current: nil,
            since: nil, index: nil, op: nil, reason: nil, fields: nil)
    }
}
