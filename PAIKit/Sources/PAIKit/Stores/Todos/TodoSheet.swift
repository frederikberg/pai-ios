import Foundation

/// The ops a todo's fields send, the web's `detail/fieldOps.ts`, `detail/nudges.ts` and the field
/// popovers by the same rules: each choice is one change through the outbox. A time on a todo is a
/// mark on its day and never notifies; only a nudge does, and a nudge is always added on purpose.
public enum TodoFieldOps {
    static func update(_ todoId: String, _ set: [String: PaiJSONValue]) -> TodoOp {
        TodoOp(fields: ["op": .string("todo.update"), "todo": .string(todoId), "set": .object(set)])
    }

    public static func title(_ todoId: String, _ title: String) -> TodoOp? {
        let clean = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : update(todoId, ["title": .string(clean)])
    }

    public static func horizon(_ todoId: String, _ horizon: TodoHorizon) -> TodoOp {
        update(todoId, ["horizon": .string(horizon.rawValue)])
    }

    /// Setting or clearing the day: one `todo.update`, never a nudge.
    public static func when(_ todoId: String, date: String?, time: String? = nil) -> TodoOp {
        update(
            todoId,
            [
                "when": date.map { .object(["date": .string($0), "time": time.map(PaiJSONValue.string) ?? .null]) }
                    ?? .null
            ])
    }

    public static func someday(_ todoId: String, _ on: Bool) -> TodoOp { update(todoId, ["someday": .bool(on)]) }

    public static func deadline(_ todoId: String, date: String?, leadDays: Int? = nil) -> TodoOp {
        update(
            todoId,
            [
                "deadline": date.map {
                    .object(["date": .string($0), "lead_days": leadDays.map { .number(Decimal($0)) } ?? .null])
                } ?? .null
            ])
    }

    public static func `repeat`(_ todoId: String, _ rule: [String: PaiJSONValue]?) -> TodoOp {
        update(todoId, ["repeat": rule.map(PaiJSONValue.object) ?? .null])
    }

    public static func tag(_ todoId: String, add: [String] = [], remove: [String] = []) -> TodoOp {
        TodoOp(fields: [
            "op": .string("todo.tag"), "todo": .string(todoId), "add": .array(add.map(PaiJSONValue.string)),
            "remove": .array(remove.map(PaiJSONValue.string)),
        ])
    }

    /// Moves a todo, with its subtasks, to another list.
    public static func move(_ todoId: String, toList list: String) -> TodoOp {
        TodoOp(fields: ["op": .string("todo.move"), "todo": .string(todoId), "list": .string(list)])
    }

    public static func body(_ todoId: String, _ text: String, ifBodyHash: String?) -> TodoOp {
        var fields: [String: PaiJSONValue] = [
            "op": .string("todo.body"), "todo": .string(todoId), "set": .string(text),
        ]
        if let ifBodyHash, ifBodyHash.count == 64 { fields["if_body_hash"] = .string(ifBodyHash) }
        return TodoOp(fields: fields)
    }

    /// Done on an earlier day: the tick backdated to midday UTC of that day.
    public static func doneOn(_ todoId: String, day: String) -> TodoOp {
        TodoOp(fields: [
            "op": .string("todo.complete"), "todo": .string(todoId), "as": .string("done"),
            "at": .string("\(day)T12:00:00+00:00"),
        ])
    }

    public static func skip(_ todoId: String) -> TodoOp {
        TodoOp(fields: ["op": .string("todo.skip"), "todo": .string(todoId)])
    }

    public static func delete(_ todoId: String) -> TodoOp {
        TodoOp(fields: ["op": .string("todo.delete"), "todo": .string(todoId)])
    }

    public static func restore(_ todoId: String) -> TodoOp {
        TodoOp(fields: ["op": .string("todo.restore"), "todo": .string(todoId)])
    }

    /// A subtask, last among its parent's open children.
    public static func subtask(id: String, parent: String, title: String) -> TodoOp {
        TodoOp(fields: [
            "op": .string("todo.create"), "id": .string(id), "parent": .string(parent), "title": .string(title),
        ])
    }

    public static func deskMove(_ item: String, position: TodoPosition) -> TodoOp {
        TodoOp(fields: ["op": .string("desk.move"), "item": .string(item), "position": position.json])
    }

    /// A new section on the desk, or a new title for one.
    public static func deskSection(id: String, title: String, position: TodoPosition? = .last) -> TodoOp {
        var fields: [String: PaiJSONValue] = [
            "op": .string("desk.divider"), "id": .string(id), "title": .string(title),
        ]
        if let position { fields["position"] = position.json }
        return TodoOp(fields: fields)
    }

    public static func clearSection(_ dividerId: String) -> TodoOp {
        TodoOp(fields: ["op": .string("desk.clear"), "what": .object(["section": .string(dividerId)])])
    }

    public enum NudgeChoice: Equatable, Sendable {
        case at(date: String, time: String)
        case before(basis: String, minutes: Int)
        /// Whole days before the day or deadline, at a time of day: it rings at that wall-clock time.
        case days(basis: String, days: Int, time: String)
    }

    public static func nudgeSet(_ todoId: String, _ choice: NudgeChoice, id: String) -> TodoOp {
        var fields: [String: PaiJSONValue] = ["op": .string("nudge.set"), "id": .string(id), "todo": .string(todoId)]
        switch choice {
        case .at(let date, let time): fields["at"] = .object(["date": .string(date), "time": .string(time)])
        case .before(let basis, let minutes):
            fields["before"] = .object(["basis": .string(basis), "minutes": .number(Decimal(minutes))])
        case .days(let basis, let days, let time):
            fields["before"] = .object([
                "basis": .string(basis), "days": .number(Decimal(days)), "time": .string(time),
            ])
        }
        return TodoOp(fields: fields)
    }

    /// Gives the todo what the person's default nudges say for the day and deadline it has now, in
    /// place of the default nudges it holds; nudges added by hand stay.
    public static func nudgeDefaults(_ todoId: String) -> TodoOp {
        TodoOp(fields: ["op": .string("nudge.defaults"), "todo": .string(todoId)])
    }

    /// Whether "Use my default nudges" has anything to do: the person has defaults, and the open
    /// todo has a day or a deadline they count from.
    public static func offersDefaults(_ todo: Todo, prefs: TodoPrefs?) -> Bool {
        guard let defaults = prefs?.defaultNudges, !defaults.isEmpty else { return false }
        return todo.status == .open && (todo.when != nil || todo.deadline != nil)
    }

    public static func nudgeRemove(_ id: String) -> TodoOp {
        TodoOp(fields: ["op": .string("nudge.remove"), "id": .string(id)])
    }

    public static func nudgeSnooze(_ id: String, minutes: Int) -> TodoOp {
        TodoOp(fields: ["op": .string("nudge.snooze"), "id": .string(id), "minutes": .number(Decimal(minutes))])
    }

    // MARK: Repeat rules, as the JSON the wire carries

    /// A new repeat for a todo that had none: every day, counted from the day it is done.
    public static let defaultRepeat: [String: PaiJSONValue] = [
        "mode": .string("after_done"), "every": .number(1), "unit": .string("day"), "skip_missed": .bool(false),
    ]

    /// A todo's repeat as the JSON object it is sent as.
    public static func repeatJSON(_ rule: TodoRepeat) -> [String: PaiJSONValue] {
        var fields: [String: PaiJSONValue] = [
            "mode": .string(rule.mode), "every": .number(Decimal(rule.every)), "unit": .string(rule.unit),
            "skip_missed": .bool(rule.skipMissed),
        ]
        if let on = rule.on { fields["on"] = on }
        if let anchor = rule.anchorDay { fields["anchor_day"] = .number(Decimal(anchor)) }
        if let until = rule.until { fields["until"] = .string(until) }
        return fields
    }

    /// The weekdays (1 = Monday) a repeat names.
    public static func weekdays(_ rule: [String: PaiJSONValue]) -> [Int] {
        guard case .object(let on) = rule["on"], case .array(let days) = on["weekdays"] else { return [] }
        return days.compactMap {
            if case .number(let value) = $0 { NSDecimalNumber(decimal: value).intValue } else { nil }
        }
    }

    /// The repeat with one weekday switched on or off; with none left the rule says none, since a
    /// weekday rule must name at least one.
    public static func toggleWeekday(_ rule: [String: PaiJSONValue], _ day: Int) -> [String: PaiJSONValue] {
        var days = Set(weekdays(rule))
        if days.contains(day) { days.remove(day) } else { days.insert(day) }
        var out = rule
        out["on"] =
            days.isEmpty ? .null : .object(["weekdays": .array(days.sorted().map { .number(Decimal($0)) })])
        return out
    }

    /// Changing the unit drops a weekday or month-day rule, which only fits the unit it was made for.
    public static func withUnit(_ rule: [String: PaiJSONValue], _ unit: String) -> [String: PaiJSONValue] {
        guard rule["unit"] != .string(unit) else { return rule }
        var out = rule
        out["unit"] = .string(unit)
        out["on"] = .null
        out["anchor_day"] = .null
        return out
    }
}

/// A description being edited: the text it started from, guarded by that text's hash, so a save
/// made after someone else changed the description is refused as a conflict instead of
/// overwriting theirs. Saved by Save and again when the screen is left; whichever comes first
/// sends it, the other finds nothing left to send.
public struct TodoBodyEdit: Equatable, Sendable {
    public let todoId: String
    public var text: String
    private var original: String
    private let originalHash: String

    /// Nil while the todo's whole description has not been read: a row carries only its first
    /// line, and editing that would save the rest away.
    public init?(_ todo: Todo) {
        guard let body = todo.body else { return nil }
        todoId = todo.id
        text = body
        original = body
        originalHash = todo.bodyHash
    }

    /// The op that saves the text, or nil when nothing changed since it began or since the last
    /// save.
    public mutating func take() -> TodoOp? {
        guard text != original else { return nil }
        original = text
        return TodoFieldOps.body(todoId, text, ifBodyHash: originalHash)
    }
}

/// How dates, repeats and nudges are said, the web's `shell/dates.ts`, `fields/days.ts`,
/// `quickadd/chips.ts` and `detail/nudges.ts`.
public enum TodoWords {
    private static func utc(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func format(_ iso: String, _ pattern: String) -> String {
        guard let date = utc(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// `YYYY-MM-DD` plus whole days.
    public static func addDays(_ iso: String, _ days: Int) -> String {
        guard let date = utc(iso) else { return iso }
        return format(date: date.addingTimeInterval(Double(days) * 86_400))
    }

    private static func format(date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 1 = Monday … 7 = Sunday.
    public static func weekday(_ iso: String) -> Int {
        guard let date = utc(iso) else { return 1 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// "26 Nov" with "Tomorrow · Friday" (or the weekday alone) beside it: a day as a heading.
    public static func dayHeading(_ date: String, today: String) -> (label: String, sub: String) {
        let diff = TodoDates.dayDiff(today, date)
        let label = format(date, date.prefix(4) == today.prefix(4) ? "d MMM" : "d MMM yyyy")
        let weekday = format(date, "EEEE")
        if diff == 0 { return (label, "Today · \(weekday)") }
        if diff == 1 { return (label, "Tomorrow · \(weekday)") }
        if diff == -1 { return (label, "Yesterday · \(weekday)") }
        return (label, weekday)
    }

    public struct QuickDay: Equatable, Sendable {
        public let label: String
        public let date: String
    }

    /// The days a picker offers as one press, each a different day: today, tomorrow, the coming
    /// Saturday (the next one once the weekend has begun) and the Monday after this week.
    public static func quickDays(_ today: String) -> [QuickDay] {
        let day = weekday(today)
        let saturday = addDays(today, day <= 5 ? 6 - day : 13 - day)
        let candidates = [
            QuickDay(label: "Today", date: today), QuickDay(label: "Tomorrow", date: addDays(today, 1)),
            QuickDay(label: day >= 6 ? "Next weekend" : "This weekend", date: saturday),
            QuickDay(label: "Next week", date: addDays(today, 8 - day)),
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.date).inserted }
    }

    static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private static func ordinal(_ day: Int) -> String {
        let rest = day % 100
        if (11...13).contains(rest) { return "\(day)th" }
        switch day % 10 {
        case 1: return "\(day)st"
        case 2: return "\(day)nd"
        case 3: return "\(day)rd"
        default: return "\(day)th"
        }
    }

    /// A repeat rule as a short phrase: "Every 2 weeks", "Every Mon, Thu", "3 months after done".
    public static func repeatRule(_ rule: [String: PaiJSONValue]) -> String {
        func int(_ key: String) -> Int {
            if case .number(let value) = rule[key] { return NSDecimalNumber(decimal: value).intValue }
            return 1
        }
        let every = int("every")
        var unit = "day"
        if case .string(let value) = rule["unit"] { unit = value }
        let plural = every == 1 ? unit : "\(unit)s"
        var text: String
        if rule["mode"] == .string("after_done") {
            text = "\(every) \(plural) after done"
        } else if case .object(let on) = rule["on"], on["weekdays"] != nil {
            let days = TodoFieldOps.weekdays(rule).sorted().map { $0 >= 1 && $0 <= 7 ? weekdayNames[$0 - 1] : "?" }
            text =
                every == 1
                ? "Every \(days.joined(separator: ", "))" : "Every \(every) weeks on \(days.joined(separator: ", "))"
        } else if case .object(let on) = rule["on"], let monthDay = on["month_day"] {
            let day: String
            if case .number(let value) = monthDay {
                day = "the \(ordinal(NSDecimalNumber(decimal: value).intValue))"
            } else {
                day = "last day"
            }
            text = every == 1 ? "Every month on \(day)" : "Every \(every) months on \(day)"
        } else {
            text = every == 1 ? "Every \(unit)" : "Every \(every) \(plural)"
        }
        if case .string(let until) = rule["until"] { text += " until \(until)" }
        return text
    }

    private static func amount(_ minutes: Int) -> String {
        let abs = Swift.abs(minutes)
        if abs % 1440 == 0 { return "\(abs / 1440) day\(abs == 1440 ? "" : "s")" }
        if abs % 60 == 0 { return "\(abs / 60) hour\(abs == 60 ? "" : "s")" }
        return "\(abs) minutes"
    }

    /// One line for a nudge: when it fires, in the person's own words.
    public static func nudge(
        kind: String, date: String?, time: String?, basis: String?, offsetMinutes: Int?, days: Int? = nil
    ) -> String {
        if kind == "at" {
            return "At \(date ?? "—") \(time.map { String($0.prefix(5)) } ?? "")".trimmingCharacters(in: .whitespaces)
        }
        if let days {
            let day = basis == "deadline" ? "the deadline" : "the day"
            let at = time.map { String($0.prefix(5)) } ?? ""
            if days == 0 { return "On \(day) at \(at)" }
            let count = Swift.abs(days)
            return "\(count) day\(count == 1 ? "" : "s") \(days > 0 ? "before" : "after") \(day) at \(at)"
        }
        let minutes = offsetMinutes ?? 0
        let basisWords = basis == "deadline" ? "the deadline" : "the time"
        if minutes == 0 { return "At \(basisWords)" }
        return "\(amount(minutes)) \(minutes > 0 ? "before" : "after") \(basisWords)"
    }

    public static func nudge(_ nudge: TodoNudge) -> String {
        Self.nudge(
            kind: nudge.kind, date: nudge.date, time: nudge.time, basis: nudge.basis,
            offsetMinutes: nudge.offsetMinutes,
            days: nudge.days)
    }

    /// A nudge as the When line says it, after the day and the repeat: "1 day before at 17:00",
    /// "15 min before", "at 08:15 on Mon, 30 Nov".
    public static func nudgeShort(_ nudge: TodoNudge) -> String {
        let at = nudge.time.map { String($0.prefix(5)) } ?? ""
        if nudge.kind == "at" {
            return "at \(at)" + (nudge.date.map { " on \(format($0, "EEE, d MMM"))" } ?? "")
        }
        if let days = nudge.days {
            if days == 0 { return "at \(at) on the \(nudge.basis == "deadline" ? "deadline day" : "day")" }
            let count = Swift.abs(days)
            let of = nudge.basis == "deadline" ? " the deadline" : ""
            return "\(count) day\(count == 1 ? "" : "s") \(days > 0 ? "before" : "after")\(of) at \(at)"
        }
        let minutes = nudge.offsetMinutes ?? 0
        if minutes == 0 { return nudge.basis == "deadline" ? "at the deadline" : "at the time" }
        let abs = Swift.abs(minutes)
        let amount =
            abs % 1440 == 0
            ? "\(abs / 1440) day\(abs == 1440 ? "" : "s")" : abs % 60 == 0 ? "\(abs / 60) h" : "\(abs) min"
        return "\(amount) \(minutes > 0 ? "before" : "after")\(nudge.basis == "deadline" ? " the deadline" : "")"
    }

    public enum StateTone: String, Sendable { case quiet, live, warn }

    /// What a nudge's state means to the person.
    public static func nudgeState(_ state: TodoNudgeState, fireAt: String?) -> (label: String, tone: StateTone) {
        switch state {
        case .armed: return (fireAt == nil ? "Waiting for a date" : "Waiting", .quiet)
        case .firing: return ("Sending", .live)
        case .fired: return ("Sent", .live)
        case .held: return ("Held for the morning", .warn)
        case .missed: return ("Missed", .warn)
        case .cancelled, .unrecognized: return ("Cancelled", .quiet)
        }
    }

    /// The offsets a nudge is offered at, before the todo's time; negative is after it.
    public static let nudgeOffsets: [(minutes: Int, label: String)] = [
        (0, "At the time"), (15, "15 minutes before"), (30, "30 minutes before"), (60, "1 hour before"),
        (1440, "1 day before"),
    ]

    /// The nudges as shown while a queued `nudge.set` or `nudge.remove` waits for its answer.
    public static func overlayNudges(_ nudges: [TodoNudge], ops: [TodoOp], todoId: String) -> [TodoNudge] {
        var out = nudges
        for op in ops {
            if op.name == "nudge.set", op.string("todo") == todoId, let id = op.string("id"),
                !out.contains(where: { $0.id == id })
            {
                let at = op.object("at")
                let before = op.object("before")
                func whole(_ key: String) -> Int? {
                    guard case .number(let value) = before?.fields[key] else { return nil }
                    return NSDecimalNumber(decimal: value).intValue
                }
                out.append(
                    TodoNudge(
                        id: id, todoId: todoId, kind: at == nil ? "before" : "at", date: at?.string("date"),
                        time: at?.string("time") ?? before?.string("time"), basis: before?.string("basis"),
                        offsetMinutes: whole("minutes"), days: whole("days"), state: .armed))
            } else if op.name == "nudge.remove", let id = op.string("id") {
                out.removeAll { $0.id == id }
            }
        }
        return out
    }
}

/// A row of a day screen: a day's heading, a todo under it, a repeat's quiet ghost, or (the
/// Logbook) one completion.
public enum TodoDayRow: Equatable, Sendable, Identifiable {
    case heading(key: String, label: String, sub: String?, date: String?, count: Int)
    case todo(key: String, id: String)
    case ghost(key: String, todoId: String, date: String)
    case entry(key: String, todoId: String, completionId: String, at: String, kind: String, byLabel: String)

    public var id: String {
        switch self {
        case .heading(let key, _, _, _, _), .todo(let key, _), .ghost(let key, _, _), .entry(let key, _, _, _, _, _):
            key
        }
    }
}

public enum TodoDays {
    /// The days ahead, the web's `upcomingRows`: a heading per day (empty days keep theirs), the
    /// todos planned for it, those due on it and the ghosts of repeating todos, then Later and
    /// Someday. A todo created or moved by a queued change shows under its new day.
    public static func upcomingRows(
        _ answer: TodosUpcomingAnswer, todos: [String: Todo], today: String, pending: [TodosQueuedChange]
    ) -> [TodoDayRow] {
        var moved: [String: String] = [:]
        var movedOrder: [String] = []
        for change in pending {
            for op in change.ops {
                var date: String?
                var id: String?
                if op.name == "todo.create" {
                    id = op.string("id")
                    date = op.object("when")?.string("date")
                } else if op.name == "todo.update" {
                    id = op.string("todo")
                    date = op.object("set")?.object("when")?.string("date")
                }
                if let id, let date {
                    if moved[id] == nil { movedOrder.append(id) }
                    moved[id] = date
                }
            }
        }
        let dates = Set(answer.days.map(\.date))
        var inDay: [String: [String]] = [:]
        var serverDay: Set<String> = []
        for day in answer.days { serverDay.formUnion(day.todos) }
        for day in answer.days {
            for id in day.todos {
                if let to = moved[id], dates.contains(to) {
                    inDay[to, default: []].append(id)
                } else {
                    inDay[day.date, default: []].append(id)
                }
            }
        }
        for id in movedOrder where !serverDay.contains(id) {
            if let date = moved[id], dates.contains(date), todos[id] != nil { inDay[date, default: []].append(id) }
        }
        func visible(_ id: String) -> Bool { todos[id].map { $0.status != .deleted } ?? false }
        var rows: [TodoDayRow] = []
        for day in answer.days {
            let planned = (inDay[day.date] ?? []).filter(visible)
            let deadlines = day.deadlines.filter { visible($0) && !planned.contains($0) }
            let ghosts = day.ghosts.filter { visible($0.todoId) }
            let heading = TodoWords.dayHeading(day.date, today: today)
            rows.append(
                .heading(
                    key: "day:\(day.date)", label: heading.label, sub: heading.sub, date: day.date,
                    count: planned.count + deadlines.count))
            for id in planned { rows.append(.todo(key: "day:\(day.date)/\(id)", id: id)) }
            for id in deadlines { rows.append(.todo(key: "day:\(day.date)/due:\(id)", id: id)) }
            for ghost in ghosts {
                rows.append(
                    .ghost(key: "day:\(day.date)/ghost:\(ghost.todoId)", todoId: ghost.todoId, date: ghost.date))
            }
        }
        for (key, label, ids) in [("later", "Later", answer.later), ("someday", "Someday", answer.someday)] {
            let shown = ids.filter(visible)
            guard !shown.isEmpty else { continue }
            rows.append(.heading(key: "section:\(key)", label: label, sub: nil, date: nil, count: shown.count))
            for id in shown { rows.append(.todo(key: "section:\(key)/\(id)", id: id)) }
        }
        return rows
    }

    /// The Logbook, the web's `logbookRows`: a heading per day, then one row per completion, so a
    /// repeating todo ticked on several days shows on each.
    public static func logbookRows(_ days: [TodosLogbookAnswer.Day], todos: [String: Todo], today: String)
        -> [TodoDayRow]
    {
        var rows: [TodoDayRow] = []
        for day in days {
            let entries = day.entries.filter { todos[$0.todoId] != nil }
            guard !entries.isEmpty else { continue }
            let heading = TodoWords.dayHeading(day.date, today: today)
            rows.append(
                .heading(
                    key: "log:\(day.date)", label: heading.label, sub: heading.sub, date: nil, count: entries.count))
            for entry in entries {
                rows.append(
                    .entry(
                        key: "log:\(entry.completionId)", todoId: entry.todoId, completionId: entry.completionId,
                        at: entry.at,
                        kind: entry.kind, byLabel: entry.byLabel))
            }
        }
        return rows
    }
}

/// Arranging the desk, the web's `dropIntent` for a desk card: the handle `desk.move` knows an
/// item by (its todo, or a section's own id), and where a moved card lands.
public enum TodoDeskArrange {
    public static func ref(_ item: TodoDeskItem) -> String {
        item.kind == .divider ? item.id : (item.todoId ?? item.id)
    }

    /// The move of the item at `from` onto the item at `over`: moving down lands after it, moving
    /// up before it. Nil when it is the same item.
    public static func move(_ desk: [TodoDeskItem], from: Int, over: Int) -> TodoOp? {
        guard desk.indices.contains(from), desk.indices.contains(over), from != over,
            TodosOverlay.deskKey(desk[from]) != TodosOverlay.deskKey(desk[over])
        else { return nil }
        let target = ref(desk[over])
        return TodoFieldOps.deskMove(ref(desk[from]), position: from < over ? .after(target) : .before(target))
    }

    /// SwiftUI's `onMove`: the destination is the index the item goes before in the list as it
    /// was. Moving down onto `destination - 1`, moving up onto `destination`.
    public static func onMove(_ desk: [TodoDeskItem], from: Int, to destination: Int) -> TodoOp? {
        let over = destination > from ? destination - 1 : destination
        return move(desk, from: from, over: over)
    }
}
