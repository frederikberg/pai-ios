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
    /// field replaces its default, tags add to the view's. The client does the overlay, so the op
    /// and the log show real values.
    public static func op(
        id: String, title: String, place: TodoCreatePlace, today: String?, typed: [String: PaiJSONValue] = [:]
    ) -> TodoOp {
        let defaults = place.defaults
        var fields: [String: PaiJSONValue] = [:]
        if let list = defaults?.list ?? place.listId { fields["list"] = .string(list) }
        let viewTags = defaults?.tags ?? []
        var tags = viewTags
        if case .array(let typedTags) = typed["tags"] {
            for case .string(let tag) in typedTags where !tags.contains(where: { $0.lowercased() == tag.lowercased() })
            {
                tags.append(tag)
            }
        }
        if !tags.isEmpty { fields["tags"] = .array(tags.map(PaiJSONValue.string)) }
        if let horizon = defaults?.horizon { fields["horizon"] = .string(horizon.rawValue) }
        if defaults?.when == "today", let today { fields["when"] = .object(["date": .string(today)]) }
        if defaults?.desk == true { fields["desk"] = .bool(true) }
        if let parent = defaults?.parent { fields["parent"] = .string(parent) }
        for (key, value) in typed where key != "tags" { fields[key] = value }
        fields["op"] = .string("todo.create")
        fields["id"] = .string(id)
        if fields["title"] == nil { fields["title"] = .string(title) }
        return TodoOp(fields: fields)
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

    public enum Tone: String, Equatable, Sendable { case neutral, today, soon, late }

    public struct Chip: Equatable, Sendable {
        public let isDeadline: Bool
        public let label: String
        public let tone: Tone
    }

    /// The date a row shows: its deadline when it is near or past, else its `when`; a deadline far
    /// off still shows, quietly, when the todo has no `when`.
    public static func chip(when: TodoWhen?, deadline: TodoDeadline?, today: String, leadDays: Int) -> Chip? {
        if let deadline {
            let diff = dayDiff(today, deadline.date)
            let lead = deadline.leadDays ?? leadDays
            let label = relativeDay(deadline.date, today: today)
            if diff < 0 { return Chip(isDeadline: true, label: label, tone: .late) }
            if diff <= lead { return Chip(isDeadline: true, label: label, tone: .soon) }
            if when == nil { return Chip(isDeadline: true, label: label, tone: .neutral) }
        }
        if let when {
            let diff = dayDiff(today, when.date)
            let label = relativeDay(when.date, today: today) + (when.time.map { " \($0)" } ?? "")
            return Chip(isDeadline: false, label: label, tone: diff <= 0 ? .today : .neutral)
        }
        return nil
    }
}
