import Foundation

/// Where a todo is being added: the open page's view defaults and its list, the web's
/// `CreateInput` without the line. A capture door adds with none.
public struct TodoCreatePlace: Codable, Equatable, Sendable {
    /// The open view's defaults: what a todo made here gets unless the line says otherwise.
    public let defaults: TodoViewDefaults?
    /// The list the open page is, when it is one.
    public let listId: String?
    /// The page (`TodoPage.key`) it is added on, which draws the new row before the server has it.
    public let page: String?

    public init(defaults: TodoViewDefaults?, listId: String?, page: String? = nil) {
        self.defaults = defaults
        self.listId = listId
        self.page = page
    }

    enum CodingKeys: String, CodingKey {
        case defaults, page
        case listId = "list_id"
    }

    public static let anywhere = TodoCreatePlace(defaults: nil, listId: nil)

    /// A subtask's place: under its parent and nothing else, so the line alone says what it is
    /// (the parent's tags, day or horizon are its own, not defaults); it lands in its parent's
    /// list.
    public static func under(parent: String) -> TodoCreatePlace {
        TodoCreatePlace(
            defaults: TodoViewDefaults(tags: nil, horizon: nil, list: nil, when: nil, desk: nil, parent: parent),
            listId: nil)
    }
}

/// How a typed line becomes a `todo.create`, the web's `typedFromParse` (`quickadd/chips.ts`) and
/// `buildCreateOp` (`shell/viewMeta.ts`) by the same rules, so a line added on the phone lands as
/// the op the browser sends for it.
public enum TodoCreate {

    /// What the parser read, as the fields of a `todo.create`; only fields the line spoke about
    /// are present, so they replace a view's default for that field and nothing else does.
    public static func typed(from answer: TodosParseAnswer) -> [String: PaiJSONValue] {
        let fields = answer.fields
        let op = answer.createOp
        var typed: [String: PaiJSONValue] = ["title": .string(op.string("title") ?? answer.title)]
        if let body = op.string("body"), !body.isEmpty { typed["body"] = .string(body) }
        if !fields.tags.isEmpty { typed["tags"] = .array(fields.tags.map(PaiJSONValue.string)) }
        if let horizon = fields.horizon { typed["horizon"] = .string(horizon.rawValue) }
        if let when = fields.when {
            typed["when"] = .object(["date": .string(when.date), "time": when.time.map(PaiJSONValue.string) ?? .null])
        }
        if fields.someday == true { typed["someday"] = .bool(true) }
        if let deadline = fields.deadline {
            typed["deadline"] = .object([
                "date": .string(deadline.date), "lead_days": deadline.leadDays.map { .number(Decimal($0)) } ?? .null,
            ])
        }
        if let repeatRule = op.fields["repeat"], repeatRule != .null, fields.repeat != nil {
            typed["repeat"] = repeatRule
        }
        if let parent = op.string("parent") { typed["parent"] = .string(parent) }
        if let list = op.string("list") { typed["list"] = .string(list) }
        if fields.desk { typed["desk"] = .bool(true) }
        if !fields.nudges.isEmpty { typed["nudges"] = .array(fields.nudges) }
        return typed
    }

    /// A `todo.create` whose fields are the place's defaults overlaid by what was typed: each typed
    /// field replaces its default, tags add to the view's. `dismissed` names the defaults left off
    /// this todo (`tag:<name>`, `horizon`, `when`, `desk`, `list`, `parent`). The client does the
    /// overlay, so the op and the log show real values.
    public static func op(
        id: String, title: String, place: TodoCreatePlace, today: String?, typed: [String: PaiJSONValue] = [:],
        dismissed: Set<String> = []
    ) -> TodoOp {
        let defaults = place.defaults
        var fields: [String: PaiJSONValue] = [:]
        if !dismissed.contains("list"), let list = defaults?.list ?? place.listId { fields["list"] = .string(list) }
        let viewTags = (defaults?.tags ?? []).filter { !dismissed.contains("tag:\($0)") }
        var tags = viewTags
        if case .array(let typedTags) = typed["tags"] {
            for case .string(let tag) in typedTags where !tags.contains(where: { $0.lowercased() == tag.lowercased() })
            {
                tags.append(tag)
            }
        }
        if !tags.isEmpty { fields["tags"] = .array(tags.map(PaiJSONValue.string)) }
        if !dismissed.contains("horizon"), let horizon = defaults?.horizon {
            fields["horizon"] = .string(horizon.rawValue)
        }
        if !dismissed.contains("when"), defaults?.when == "today", let today {
            fields["when"] = .object(["date": .string(today)])
        }
        if !dismissed.contains("desk"), defaults?.desk == true { fields["desk"] = .bool(true) }
        if !dismissed.contains("parent"), let parent = defaults?.parent { fields["parent"] = .string(parent) }
        for (key, value) in typed where key != "tags" { fields[key] = value }
        fields["op"] = .string("todo.create")
        fields["id"] = .string(id)
        if fields["title"] == nil { fields["title"] = .string(title) }
        return TodoOp(fields: fields)
    }

    /// What the person dismissed, plus the day the line itself cleared: "no date" drops the
    /// view's day.
    public static func cleared(_ dismissed: Set<String>, answer: TodosParseAnswer?) -> Set<String> {
        guard answer?.clears.contains("when") == true else { return dismissed }
        return dismissed.union(["when", "fixed-when"])
    }

    /// The model's creates laid over the place's defaults, as for every add: a field the model
    /// left empty (absent, null, false or an empty list) takes the view's value, tags add to the
    /// view's. A subtask goes as it is: it lives where its parent does.
    public static func withViewDefaults(_ ops: [TodoOp], place: TodoCreatePlace, today: String?) -> [TodoOp] {
        ops.map { op in
            if let parent = op.fields["parent"], parent != .null { return op }
            var said: [String: PaiJSONValue] = [:]
            for (key, value) in op.fields where !["op", "id", "title"].contains(key) {
                switch value {
                case .null, .bool(false): continue
                case .array(let items) where items.isEmpty: continue
                default: said[key] = value
                }
            }
            return Self.op(
                id: op.string("id") ?? "", title: op.string("title") ?? "", place: place, today: today, typed: said)
        }
    }
}

/// Words the add sheet's taps put into the line: the line stays the one source of truth, so a
/// tap is typing (the web's `PILLS` and `insert` in `quickadd/QuickAdd.tsx`).
public enum TodoAddWords {
    public struct Tap: Equatable, Sendable {
        public let label: String
        public let insert: String
    }

    public static let taps: [Tap] = [
        Tap(label: "Today", insert: "today"), Tap(label: "Tomorrow", insert: "tomorrow"),
        Tap(label: "@ Tag", insert: "@"), Tap(label: TodoHorizonMark.of(.now).label, insert: "p1"),
        Tap(label: "Desk", insert: "*"),
        Tap(label: "Deadline", insert: "by "),
    ]

    /// The line with `piece` put at `caret` (a UTF-16 offset), a space before it when the word
    /// before does not end in one, and one after it unless it is meant to be typed on from; the
    /// caret lands at the end of the piece.
    public static func insert(_ piece: String, into text: String, at caret: Int) -> (text: String, caret: Int) {
        let units = Array(text.utf16)
        let at = max(0, min(caret, units.count))
        let before = String(decoding: units[..<at], as: UTF16.self)
        let after = String(decoding: units[at...], as: UTF16.self)
        let glue = !before.isEmpty && !(before.last?.isWhitespace ?? false) ? " " : ""
        let joined = before + glue + piece
        let tail = piece.hasSuffix(" ") || piece == "@" ? "" : " "
        return (joined + tail + after, joined.utf16.count)
    }
}

/// One chip under the add sheet's line: what the parser read, a default of the open view
/// (`dismissKey` set, a tap leaves it off this todo), or a picker's choice. The web's `Chip`
/// (`quickadd/chips.ts`).
public struct TodoAddChip: Equatable, Sendable, Identifiable {
    public let key: String
    public let kind: String
    public let label: String
    /// A chip that wears a palette colour of its own (a horizon's) instead of its kind's tone.
    public let color: TodoColor?
    public let dismissKey: String?

    public var id: String { key }

    public init(key: String, kind: String, label: String, color: TodoColor? = nil, dismissKey: String? = nil) {
        self.key = key
        self.kind = kind
        self.label = label
        self.color = color
        self.dismissKey = dismissKey
    }

    /// The chips for what the parser read in a line: one per field, in a fixed order, named from
    /// the fields themselves, never from the typed words.
    public static func read(_ answer: TodosParseAnswer?, today: String) -> [TodoAddChip] {
        guard let answer else { return [] }
        let fields = answer.fields
        var chips: [TodoAddChip] = []
        if let when = fields.when {
            let label = TodoDates.relativeDay(when.date, today: today) + (when.time.map { " \($0)" } ?? "")
            chips.append(TodoAddChip(key: "when", kind: "when", label: label))
        }
        if let deadline = fields.deadline {
            chips.append(
                TodoAddChip(
                    key: "deadline", kind: "deadline",
                    label: "Deadline \(TodoDates.relativeDay(deadline.date, today: today))"))
        }
        if let rule = fields.repeat {
            chips.append(
                TodoAddChip(key: "repeat", kind: "repeat", label: TodoWords.repeatRule(TodoFieldOps.repeatJSON(rule))))
        }
        if let horizon = fields.horizon {
            let mark = TodoHorizonMark.of(horizon)
            chips.append(TodoAddChip(key: "horizon", kind: "horizon", label: mark.label, color: mark.color))
        }
        // Someday takes the day away too; its own chip says so, in place of "No date".
        if fields.someday == true {
            chips.append(TodoAddChip(key: "someday", kind: "when", label: "Someday"))
        } else if answer.clears.contains("when") {
            chips.append(TodoAddChip(key: "clear:when", kind: "clear", label: "No date"))
        }
        for name in fields.tags { chips.append(TodoAddChip(key: "tag:\(name)", kind: "tag", label: name)) }
        if let list = fields.list { chips.append(TodoAddChip(key: "list", kind: "list", label: list)) }
        if let parent = fields.parent {
            chips.append(TodoAddChip(key: "parent", kind: "parent", label: "Under \(parent)"))
        }
        if fields.desk { chips.append(TodoAddChip(key: "desk", kind: "desk", label: "Desk")) }
        for nudge in fields.nudges {
            guard case .object(let spec) = nudge else { continue }
            chips.append(
                TodoAddChip(key: "nudge:\(spec["id"]?.stringValue ?? "")", kind: "nudge", label: nudgeLabel(spec)))
        }
        return chips
    }

    private static func nudgeLabel(_ spec: [String: PaiJSONValue]) -> String {
        if case .object(let at) = spec["at"] { return "Nudge \(at["time"]?.stringValue ?? "")" }
        guard case .object(let before) = spec["before"] else { return "Nudge" }
        func whole(_ key: String) -> Int? {
            guard case .number(let value) = before[key] else { return nil }
            return NSDecimalNumber(decimal: value).intValue
        }
        if let minutes = whole("minutes") {
            return "Nudge \(abs(minutes)) min \(minutes >= 0 ? "before" : "after")"
        }
        if let days = whole("days") {
            return "Nudge \(abs(days)) d \(days >= 0 ? "before" : "after") \(before["time"]?.stringValue ?? "")"
                .trimmingCharacters(in: .whitespaces)
        }
        return "Nudge"
    }

    /// The chips a view's defaults put on a todo made inside it, minus the ones dismissed and
    /// the ones the line itself names, the web's `defaultChips` and `standingDefaults`: a field
    /// the line names replaces the view's value for it (`TodoCreate.op`), so its default chip
    /// goes; tags add up, so theirs stay.
    public static func defaults(
        _ defaults: TodoViewDefaults?, dismissed: Set<String>, typed: TodosParseAnswer? = nil,
        listName: (String) -> String?
    ) -> [TodoAddChip] {
        guard let defaults else { return [] }
        let named = Set(read(typed, today: "").map(\.kind).filter { $0 != "tag" })
        var chips: [TodoAddChip] = []
        func add(_ dismissKey: String, _ kind: String, _ label: String, _ color: TodoColor? = nil) {
            guard !dismissed.contains(dismissKey), kind == "tag" || !named.contains(kind) else { return }
            chips.append(
                TodoAddChip(key: "view:\(dismissKey)", kind: kind, label: label, color: color, dismissKey: dismissKey))
        }
        for tag in defaults.tags ?? [] { add("tag:\(tag)", "tag", tag) }
        if let horizon = defaults.horizon {
            let mark = TodoHorizonMark.of(horizon)
            add("horizon", "horizon", mark.label, mark.color)
        }
        if defaults.when == "today" { add("when", "when", "Today") }
        if defaults.desk == true { add("desk", "desk", "Desk") }
        if let list = defaults.list { add("list", "list", listName(list) ?? "List") }
        if defaults.parent != nil { add("parent", "parent", "Subtask") }
        return chips
    }
}

/// Dates as a row says them, the web's `shell/dates.ts`: day-month, 24 h, English.
public enum TodoDates {
    private static func utcDay(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Whole days from `from` to `to` (both `YYYY-MM-DD`); negative when `to` is earlier.
    public static func dayDiff(_ from: String, _ to: String) -> Int {
        guard let start = utcDay(from), let end = utcDay(to) else { return 0 }
        return Int((end.timeIntervalSince(start) / 86_400).rounded())
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// Today, Tomorrow, Yesterday, a weekday within the week, else the date (with the year when it
    /// is not this one).
    public static func relativeDay(_ date: String, today: String) -> String {
        let diff = dayDiff(today, date)
        if diff == 0 { return "Today" }
        if diff == 1 { return "Tomorrow" }
        if diff == -1 { return "Yesterday" }
        guard let at = utcDay(date) else { return date }
        if diff > 1, diff < 7 { return format(at, "EEE") }
        return format(at, date.prefix(4) == today.prefix(4) ? "d MMM" : "d MMM yyyy")
    }

    /// How near a date is, which is the colour it is written in: red once it is past, yellow on
    /// the day, blue within the next seven days, plain beyond. A day and a deadline are read by
    /// the same scale.
    public enum Light: String, Equatable, Sendable { case late, today, week, later }

    /// A date as a row writes it: its words and how near it is.
    public struct Mark: Equatable, Sendable {
        public let label: String
        public let light: Light
    }

    /// `clock` is the person's time of day (`HH:mm`): a time of today that has passed is late.
    public static func light(date: String, time: String? = nil, today: String, clock: String? = nil) -> Light {
        let diff = dayDiff(today, date)
        if diff < 0 { return .late }
        if diff == 0 {
            if let time, let clock, time.prefix(5) < clock.prefix(5) { return .late }
            return .today
        }
        return diff <= 7 ? .week : .later
    }

    /// The day a todo is planned for, with its time.
    public static func dayMark(_ when: TodoWhen?, today: String, clock: String? = nil) -> Mark? {
        guard let when else { return nil }
        let label = relativeDay(when.date, today: today) + (when.time.map { " \($0.prefix(5))" } ?? "")
        return Mark(label: label, light: light(date: when.date, time: when.time, today: today, clock: clock))
    }

    /// The day a todo is owed, in its short form: a deadline days back counts them ("3 d ago").
    public static func deadlineMark(_ deadline: TodoDeadline?, today: String) -> Mark? {
        guard let deadline else { return nil }
        let diff = dayDiff(today, deadline.date)
        let label = diff < -1 ? "\(-diff) d ago" : relativeDay(deadline.date, today: today)
        return Mark(label: label, light: light(date: deadline.date, today: today))
    }
}
