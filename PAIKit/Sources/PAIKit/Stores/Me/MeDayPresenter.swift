import Foundation

// What the Me screens draw about one day: the ribbon, the body lines, the Todoist and plan cards,
// the grid cells and the day's fact lines. Pure functions of the models, so a day boundary, a
// missing value or an unknown kind is covered by tests and the views only draw.

/// A stretch of a day in minutes since the Berlin wall-clock midnight, `0...1440`.
public struct MeSpan: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// A diary entry on the ribbon: when, and the face it carries.
public struct MeRibbonDot: Equatable, Sendable {
    public let minute: Double
    public let feel: SelfReportFeel?
    public let isPrivate: Bool
}

/// One day on a 00:00 to 24:00 axis: what the body did, what was planned, when the person wrote,
/// when tasks were ticked. A lane without data is an empty track, never a label saying so.
public struct MeRibbon: Equatable, Sendable {
    public static let minutesPerDay = 1440.0

    public var sleep: MeSpan?
    public var activities: [MeSpan] = []
    public var plans: [MeSpan] = []
    public var you: [MeSpan] = []
    /// A ticked task is a stretch with no length; a day's grouped ticks span first to last.
    public var done: [MeSpan] = []
    public var diary: [MeRibbonDot] = []
    /// The minute of "now", only for today.
    public var now: Double?

    /// The card is drawn whenever at least one lane has something in it.
    public var hasData: Bool {
        sleep != nil || !activities.isEmpty || !plans.isEmpty || !you.isEmpty || !done.isEmpty
    }
}

/// A run of text in a line: the figure is strong, the words around it are not.
public struct MeTextRun: Equatable, Sendable {
    public let text: String
    public let strong: Bool

    public init(_ text: String, strong: Bool = false) {
        self.text = text
        self.strong = strong
    }
}

/// The three lines under the ribbon; a line without data is empty and not drawn.
public struct MeBodyLines: Equatable, Sendable {
    public var sleep: [MeTextRun] = []
    public var battery: [MeTextRun] = []
    public var movement: [MeTextRun] = []

    public var isEmpty: Bool { sleep.isEmpty && battery.isEmpty && movement.isEmpty }
}

/// What a fact line in the day's detail is about, which the view maps to a colour.
public enum MeFactTone: Equatable, Sendable {
    case sleep, movement, calendar, ambient, you, agents, done, morning
}

public struct MeFact: Equatable, Sendable {
    public let text: String
    public let tone: MeFactTone
}

/// The Todoist card of Today: fixed calendar events, what is left, what was ticked.
public struct MeTodayCard: Equatable, Sendable {
    public struct Fixed: Equatable, Sendable {
        /// `14:00`; nil for an all-day event, which the row names "all day".
        public let time: String?
        public let title: String
        /// `until 15:00`.
        public let suffix: String?
    }

    public struct Open: Equatable, Sendable {
        public let id: String
        public let title: String
        /// `17:00 · latest Fri · overdue 2 d`, the parts that exist.
        public let suffix: String?
    }

    public struct Done: Equatable, Sendable {
        public let key: String
        public let title: String
        /// `09:42`, or `16:02–16:25` for a group.
        public let time: String
        public let isGroup: Bool
    }

    public let fixed: [Fixed]
    public let open: [Open]
    public let done: [Done]
    /// `3 done · 6 to come · 1 fixed`; nil when all three are empty.
    public let countLine: String?
    /// `Todoist unreachable · showing 14:02` when the read failed.
    public let footer: String?
}

/// The Plan card: the agreed text, and what is worth saying about it.
public struct MePlanCard: Equatable, Sendable {
    public let text: String
    public let appetite: String?
    /// `as agreed this morning · 08:14`.
    public let agreed: String?
    /// `2 of 3 done, 1 added later`.
    public let progress: String?
}

/// A deep link into Todoist and the web page to fall back to when the app is not installed.
public struct MeTodoistLink: Equatable, Sendable {
    public let app: String
    public let web: String

    public static let today = MeTodoistLink(app: "todoist://today", web: "https://app.todoist.com/app/today")

    public static func task(id: String) -> MeTodoistLink {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return MeTodoistLink(app: "todoist://task?id=\(safe)", web: "https://app.todoist.com/app/task/\(safe)")
    }
}

/// One dot of the grid's diary row.
public enum MeDiaryDot: Equatable, Sendable {
    case face(SelfReportFeel)
    /// An entry without a face: a hollow ring.
    case noFace
    /// A private entry without a face.
    case privateNoFace
}

/// The sleep bar of one grid column, in points from the top of the 56-point night row.
public struct MeNightBar: Equatable, Sendable {
    public let top: Double
    public let height: Double
}

/// How many entries the days on screen hold: counts only, never a share or a comparison.
public struct MeDiaryCounts: Equatable, Sendable {
    public var all = 0
    public var good = 0
    public var okay = 0
    public var heavy = 0
    public var locked = 0
}

/// A project the day held, with what its topics add up to.
public struct MeWorkedProject: Equatable, Sendable, Identifiable {
    public let name: String
    public let topics: Int
    public let minutes: Int
    public let phases: [MeHeldPhase]

    public var id: String { name }
}

public struct MeWorkedOn: Equatable, Sendable {
    public let shown: [MeWorkedProject]
    public let rest: [MeWorkedProject]

    /// `+ 4 more under 5 min` when every hidden project is short, `+ 4 more` otherwise.
    public var restLabel: String? {
        guard !rest.isEmpty else { return nil }
        let short = rest.allSatisfy { $0.minutes < MeWorkedOn.shortMinutes }
        return short ? "+ \(rest.count) more under \(MeWorkedOn.shortMinutes) min" : "+ \(rest.count) more"
    }

    static let shortMinutes = 5
    static let shownRows = 6
}

extension MePresenter {

    // MARK: Time on the day's axis

    /// Wall-clock minutes since midnight of the zone, seconds as a fraction.
    public func minuteOfDay(_ date: Date) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let whole = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return Double(whole) + Double(parts.second ?? 0) / 60
    }

    /// The part of `start...end` that lies on the day `key`, cut at its midnights; nil when none
    /// of it does. A stretch ending exactly at midnight belongs to the day before.
    public func span(start: Date, end: Date, onDay key: String) -> MeSpan? {
        let startKey = dayKey(start)
        let endKey = dayKey(end)
        if startKey > key || endKey < key { return nil }
        let from = startKey < key ? 0 : minuteOfDay(start)
        let to = endKey > key ? MeRibbon.minutesPerDay : minuteOfDay(end)
        if startKey < key && to == 0 { return nil }
        return MeSpan(start: from, end: max(from, to))
    }

    /// Neighbouring five-minute slots merged into one stretch each.
    public func slotSpans(_ slots: [Int]) -> [MeSpan] {
        let valid = Set(slots).filter { $0 >= 0 && $0 < 288 }.sorted()
        var spans: [MeSpan] = []
        var first: Int?
        var last = 0
        for slot in valid {
            if first != nil, slot == last + 1 {
                last = slot
                continue
            }
            if let begun = first { spans.append(MeSpan(start: Double(begun * 5), end: Double((last + 1) * 5))) }
            first = slot
            last = slot
        }
        if let begun = first { spans.append(MeSpan(start: Double(begun * 5), end: Double((last + 1) * 5))) }
        return spans
    }

    /// The hours labelled under the ribbon; the 21 is dropped on a narrow one, where it would run
    /// into the 22:00 mark.
    public static func ribbonHours(width: Double) -> [Int] {
        width < 420 ? [6, 9, 12, 15, 18] : [6, 9, 12, 15, 18, 21]
    }

    /// The day on the ribbon. `now` is drawn only when it falls on this day; `tasks` are the
    /// day's own Todoist rows.
    public func ribbon(day: MeDay, tasks: MeTasks?, now: Date?) -> MeRibbon {
        var ribbon = MeRibbon()
        ribbon.sleep = sleepSpan(day)
        for activity in day.activities {
            guard let wire = activity.startAt, let start = IsoTimestamp.date(from: wire) else { continue }
            let end = start.addingTimeInterval(Double(activity.durationS ?? 0))
            if let found = span(start: start, end: end, onDay: day.date) { ribbon.activities.append(found) }
        }
        for event in day.events where event.isPlan && !event.allDay {
            guard let wire = event.startAt, let start = IsoTimestamp.date(from: wire) else { continue }
            let end = event.endAt.flatMap { IsoTimestamp.date(from: $0) } ?? start
            if let found = span(start: start, end: max(start, end), onDay: day.date) { ribbon.plans.append(found) }
        }
        ribbon.you = slotSpans(day.pai?.slots ?? [])
        for row in tasks?.done ?? [] {
            guard let last = IsoTimestamp.date(from: row.completedAt) else { continue }
            let first = row.fromAt.flatMap { IsoTimestamp.date(from: $0) } ?? last
            if let found = span(start: min(first, last), end: last, onDay: day.date) { ribbon.done.append(found) }
        }
        ribbon.done.sort { $0.start < $1.start }
        for entry in day.entries {
            guard let moment = entry.date, dayKey(moment) == day.date else { continue }
            ribbon.diary.append(MeRibbonDot(minute: minuteOfDay(moment), feel: entry.feel, isPrivate: entry.isPrivate))
        }
        if let now, dayKey(now) == day.date { ribbon.now = minuteOfDay(now) }
        return ribbon
    }

    /// Bed to wake; without a bed time, the hours asleep counted back from waking.
    private func sleepSpan(_ day: MeDay) -> MeSpan? {
        guard let body = day.body, let wakeWire = body.wakeAt, let wake = IsoTimestamp.date(from: wakeWire)
        else { return nil }
        let start: Date
        if let bedWire = body.bedAt, let bed = IsoTimestamp.date(from: bedWire) {
            start = bed
        } else if let seconds = body.sleepSeconds {
            start = wake.addingTimeInterval(-Double(seconds))
        } else {
            return nil
        }
        return span(start: start, end: wake, onDay: day.date)
    }

    // MARK: Lines under the ribbon

    /// `6 h 37 asleep · 00:35 → 07:42 · score 47`, the battery and the latest activity. Parts
    /// without data are left out.
    public func bodyLines(day: MeDay?) -> MeBodyLines {
        var lines = MeBodyLines()
        guard let day else { return lines }
        if let body = day.body {
            lines.sleep = sleepRuns(body)
            if let battery = body.bodyBatteryWake {
                lines.battery = [MeTextRun("\(battery)", strong: true), MeTextRun(" body battery on waking")]
            }
        }
        if let activity = day.activities.last, let length = duration(seconds: activity.durationS) {
            var tail = " "
            if let emoji = activity.emoji { tail += "\(emoji) " }
            tail += activity.name ?? activity.type ?? "activity"
            if let started = clock(wire: activity.startAt) { tail += " · \(started)" }
            lines.movement = [MeTextRun(length, strong: true), MeTextRun(tail)]
        }
        return lines
    }

    private func sleepRuns(_ body: MeBody) -> [MeTextRun] {
        var runs: [MeTextRun] = []
        var tail = ""
        if let slept = hoursMinutes(seconds: body.sleepSeconds) {
            runs.append(MeTextRun(slept, strong: true))
            tail = " asleep"
        }
        if let window = sleepWindow(body) {
            tail += tail.isEmpty ? window : " · \(window)"
        }
        if let score = body.sleepScore {
            tail += (tail.isEmpty ? "score " : " · score ")
            runs.append(MeTextRun(tail))
            runs.append(MeTextRun("\(score)", strong: true))
            return runs
        }
        if !tail.isEmpty { runs.append(MeTextRun(tail)) }
        return runs
    }

    /// `00:35 → 07:42`, or `woke 07:42` when the bed time is missing.
    private func sleepWindow(_ body: MeBody) -> String? {
        guard let woke = clock(wire: body.wakeAt) else { return nil }
        if let bed = clock(wire: body.bedAt) { return "\(bed) → \(woke)" }
        return "woke \(woke)"
    }

    // MARK: A day's fact lines

    /// The lines of the day's detail, in the order they are read: the night, what moved, the
    /// calendar, what was written, the agents' night, the ticked tasks, the morning.
    public func facts(day: MeDay, tasks: MeTasks?, garmin: Bool) -> [MeFact] {
        var facts: [MeFact] = []
        if garmin, let body = day.body, let night = nightFact(body) {
            facts.append(MeFact(text: night, tone: .sleep))
        }
        if garmin {
            for activity in day.activities {
                let name = activity.name?.capitalized ?? activity.type ?? "Activity"
                let title = "\(activity.emoji ?? "") \(name)".trimmingCharacters(in: .whitespaces)
                let parts: [String?] = [
                    title, clock(wire: activity.startAt), duration(seconds: activity.durationS),
                    kilometres(meters: activity.distanceM),
                ]
                facts.append(MeFact(text: parts.compactMap { $0 }.joined(separator: " · "), tone: .movement))
            }
        }
        for event in day.events where event.isPlan {
            facts.append(MeFact(text: eventDetailLine(event), tone: .calendar))
        }
        for event in day.events where !event.isPlan {
            facts.append(MeFact(text: eventDetailLine(event), tone: .ambient))
        }
        if let pai = day.pai, pai.messages > 0 {
            facts.append(MeFact(text: wroteLine(pai), tone: .you))
        }
        if let minutes = day.pai?.overnightAgentMinutes, let label = overnightHours(minutes: minutes) {
            facts.append(MeFact(text: "Agents ran \(label) overnight", tone: .agents))
        }
        if let line = tasksDoneLine(tasks) { facts.append(MeFact(text: line, tone: .done)) }
        if let morning = morningLine(day) { facts.append(MeFact(text: morning, tone: .morning)) }
        return facts
    }

    /// `Night 23:05 → 02:02 · 2 h 51 asleep · score 37 · battery on waking 47`.
    public func nightFact(_ body: MeBody) -> String? {
        let window = sleepWindow(body)
        var parts: [String] = []
        if let window { parts.append(window) }
        if let slept = hoursMinutes(seconds: body.sleepSeconds) { parts.append("\(slept) asleep") }
        if let score = body.sleepScore { parts.append("score \(score)") }
        if let battery = body.bodyBatteryWake { parts.append("battery on waking \(battery)") }
        guard !parts.isEmpty else { return nil }
        return (window == nil ? "Night · " : "Night ") + parts.joined(separator: " · ")
    }

    /// `Status call 14:00–15:00`; an all-day event says so.
    public func eventDetailLine(_ event: MeEvent) -> String {
        if event.allDay { return "\(event.title) · all day" }
        guard let start = clock(wire: event.startAt) else { return event.title }
        guard let end = clock(wire: event.endAt) else { return "\(event.title) \(start)" }
        return "\(event.title) \(start)–\(end)"
    }

    /// `You wrote 22 messages in 6 sessions · 04:24 → 21:50`.
    public func wroteLine(_ pai: MePai) -> String {
        var line = "You wrote \(pai.messages) message\(pai.messages == 1 ? "" : "s")"
        if let sessions = pai.sessions { line += " in \(sessions) session\(sessions == 1 ? "" : "s")" }
        if let first = clock(wire: pai.firstMessageAt), let last = clock(wire: pai.lastMessageAt) {
            line += " · \(first) → \(last)"
        }
        return line
    }

    /// Whole hours of the agents' night, only from 45 minutes on: a shorter run is not a night
    /// left running.
    public func overnightHours(minutes: Int?) -> String? {
        guard let minutes, minutes >= 45 else { return nil }
        return "\(Int((Double(minutes) / 60).rounded())) h"
    }

    /// `4 tasks done · first 10:05, last 18:40`; nil when nothing was ticked.
    public func tasksDoneLine(_ tasks: MeTasks?) -> String? {
        guard let tasks, !tasks.done.isEmpty else { return nil }
        var moments: [Date] = []
        var count = 0
        for row in tasks.done {
            count += row.size
            if let moment = IsoTimestamp.date(from: row.completedAt) { moments.append(moment) }
            if let from = row.fromAt, let moment = IsoTimestamp.date(from: from) { moments.append(moment) }
        }
        let noun = count == 1 ? "task" : "tasks"
        guard let first = moments.min(), let last = moments.max() else { return "\(count) \(noun) done" }
        if count == 1 || clock(first) == clock(last) { return "\(count) \(noun) done · \(clock(last))" }
        return "\(count) \(noun) done · first \(clock(first)), last \(clock(last))"
    }

    // MARK: Today's cards

    /// The Todoist card. Nil when Todoist is not connected or nothing has been read yet; a failed
    /// read still shows the rows it holds, with a footer saying when they are from.
    public func todayCard(tasks: MeTasks?, events: [MeEvent], now: Date, todayKey: String) -> MeTodayCard? {
        guard let tasks, tasks.isConfigured else { return nil }
        let fixed = fixedRows(events, now: now)
        let open = tasks.open.map { MeTodayCard.Open(id: $0.id, title: $0.title, suffix: openSuffix($0, todayKey)) }
        var done: [MeTodayCard.Done] = []
        var ticked = 0
        for row in tasks.done {
            ticked += row.size
            done.append(doneRow(row))
        }
        var counts: [String] = []
        if ticked > 0 { counts.append("\(ticked) done") }
        if !open.isEmpty { counts.append("\(open.count) to come") }
        if !fixed.isEmpty { counts.append("\(fixed.count) fixed") }
        var footer: String?
        if case .unavailable = tasks.status {
            let shown = clock(wire: tasks.asOf).map { " · showing \($0)" } ?? ""
            footer = "Todoist unreachable\(shown)"
        }
        return MeTodayCard(
            fixed: fixed, open: open, done: done,
            countLine: counts.isEmpty ? nil : counts.joined(separator: " · "), footer: footer)
    }

    /// Plan events that have not ended, all-day ones first, then by start.
    private func fixedRows(_ events: [MeEvent], now: Date) -> [MeTodayCard.Fixed] {
        var allDay: [MeTodayCard.Fixed] = []
        var timed: [(start: Date, row: MeTodayCard.Fixed)] = []
        for event in events where event.isPlan {
            if event.allDay {
                allDay.append(MeTodayCard.Fixed(time: nil, title: event.title, suffix: nil))
                continue
            }
            guard let startWire = event.startAt, let start = IsoTimestamp.date(from: startWire) else { continue }
            let end = event.endAt.flatMap { IsoTimestamp.date(from: $0) }
            if let end, end <= now { continue }
            let suffix = end.map { "until \(clock($0))" }
            timed.append((start, MeTodayCard.Fixed(time: clock(start), title: event.title, suffix: suffix)))
        }
        timed.sort { $0.start < $1.start }
        return allDay + timed.map { $0.row }
    }

    private func openSuffix(_ task: MeTaskOpen, _ todayKey: String) -> String? {
        var parts: [String] = []
        if let time = task.dueTime { parts.append(time) }
        if let deadline = task.deadline { parts.append("latest \(deadlineLabel(deadline, todayKey: todayKey))") }
        if task.overdueDays > 0 { parts.append("overdue \(task.overdueDays) d") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `today`, a weekday for the coming week, else the date.
    public func deadlineLabel(_ key: String, todayKey: String) -> String {
        if key == todayKey { return "today" }
        for offset in 1...6 where shift(key: todayKey, byDays: offset) == key {
            return date(forKey: key).map { format($0, "EEE") } ?? key
        }
        return date(forKey: key).map { format($0, "d MMM") } ?? key
    }

    private func doneRow(_ row: MeTaskDone) -> MeTodayCard.Done {
        if case .group = row.kind {
            let first = clock(wire: row.fromAt)
            let last = clock(wire: row.completedAt) ?? ""
            let time = first.map { $0 == last ? last : "\($0)–\(last)" } ?? last
            return MeTodayCard.Done(
                key: row.rowKey, title: "🛒 \(row.size) \(row.title) items", time: time, isGroup: true)
        }
        return MeTodayCard.Done(
            key: row.rowKey, title: row.title, time: clock(wire: row.completedAt) ?? "", isGroup: false)
    }

    /// The Plan card; nil without stored words. Counts alone are not a plan to show.
    public func planCard(_ plan: MePlan?, todayKey: String) -> MePlanCard? {
        guard let plan, let text = plan.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return MePlanCard(
            text: text, appetite: plan.appetite, agreed: agreedLine(plan.updatedAt, todayKey: todayKey),
            progress: progressLine(plan))
    }

    private func agreedLine(_ wire: String?, todayKey: String) -> String? {
        guard let wire, let moment = IsoTimestamp.date(from: wire) else { return nil }
        let time = clock(moment)
        if dayKey(moment) != todayKey { return "as agreed \(shortDay(key: dayKey(moment))) · \(time)" }
        let morning = calendar.component(.hour, from: moment) < 12
        return morning ? "as agreed this morning · \(time)" : "as agreed · \(time)"
    }

    /// `2 of 3 done, 1 added later`.
    public func progressLine(_ plan: MePlan) -> String? {
        var parts: [String] = []
        if let planned = plan.planned, let done = plan.done { parts.append("\(done) of \(planned) done") }
        if let added = plan.added, added > 0 { parts.append("\(added) added later") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// `Garmin 10:31 · Todoist 2 min ago · today not final`: when each source last answered well; a
    /// source that is not connected or failed is left out.
    public func sourcesLine(overview: MeOverview, tasks: MeTasks?, todayFinal: Bool?, now: Date) -> String? {
        var parts: [String] = []
        var garminOk = false
        if let garmin = overview.sources.garmin, case .ok = garmin.status { garminOk = true }
        if garminOk, let at = clock(wire: overview.sources.garmin?.asOf) { parts.append("Garmin \(at)") }
        if let tasks, case .ok = tasks.status, let wire = tasks.asOf, let read = IsoTimestamp.date(from: wire) {
            parts.append("Todoist \(ago(read, now: now))")
        }
        if garminOk, todayFinal == false { parts.append("today not final") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func ago(_ moment: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(moment)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return clock(moment)
    }

    // MARK: The 14-day grid

    /// The grid's night row: 4 points an hour from 21:00 to 11:00.
    public static let nightPointsPerHour = 4.0
    public static let nightRowHeight = 56.0

    /// Which end of a night an hour is for; an hour of the day outside the axis (11:00 to 21:00)
    /// clamps to the nearer end for it: a bedtime to the top, a waking time to the bottom.
    public enum NightRole { case bed, wake }

    private static let nightAxisStart = 21.0

    /// Where an hour of the clock sits on the night row: 21:00 at the top, 11:00 at the bottom.
    /// The same rule as the web's `nightY` (`meModel.ts`).
    public static func nightY(hour: Double, role: NightRole) -> Double {
        let onAxis: Double
        if hour >= nightAxisStart {
            onAxis = hour
        } else if hour < 11 {
            onAxis = hour + 24
        } else {
            onAxis = role == .bed ? nightAxisStart : nightAxisStart + 14
        }
        return min(nightRowHeight, max(0, (onAxis - nightAxisStart) * nightPointsPerHour))
    }

    /// Bed to wake on the 21:00 to 11:00 axis, clamped at its edges. Without a bed time the bar
    /// ends at waking and is as tall as the hours asleep.
    public func nightBar(_ body: MeBody?) -> MeNightBar? {
        guard let body, let wake = hourOfDay(wire: body.wakeAt) else { return nil }
        let bottom = Self.nightY(hour: wake, role: .wake)
        let top: Double
        if let bed = hourOfDay(wire: body.bedAt) {
            top = Self.nightY(hour: bed, role: .bed)
        } else if let seconds = body.sleepSeconds {
            top = max(0, bottom - Double(seconds) / 3600 * Self.nightPointsPerHour)
        } else {
            return nil
        }
        return MeNightBar(top: top, height: max(2, bottom - top))
    }

    private func hourOfDay(wire: String?) -> Double? {
        guard let wire, let moment = IsoTimestamp.date(from: wire) else { return nil }
        return minuteOfDay(moment) / 60
    }

    /// One dot per entry, at most six.
    public func diaryDots(_ entries: [SelfReport], limit: Int = 6) -> [MeDiaryDot] {
        entries.prefix(limit).map { entry in
            if let feel = entry.feel { return .face(feel) }
            return entry.isPrivate ? .privateNoFace : .noFace
        }
    }

    /// Height of a message bar against the busiest day on screen: 28 points at most, 2 at least.
    public func messageBarHeight(messages: Int, busiest: Int) -> Double {
        guard busiest > 0 else { return 2 }
        return max(2, Double(messages) / Double(busiest) * 28)
    }

    public func busiestDay(_ days: [MeDay]) -> Int {
        days.map { $0.pai?.messages ?? 0 }.max() ?? 0
    }

    /// `6h` in the agents row, only when they ran 45 minutes or more.
    public func overnightLabel(minutes: Int?) -> String? {
        overnightHours(minutes: minutes).map { $0.replacingOccurrences(of: " ", with: "") }
    }

    // MARK: Diary

    /// How many entries the given days hold, by face and private.
    public func diaryCounts(days: [MeDay]) -> MeDiaryCounts {
        var counts = MeDiaryCounts()
        for entry in days.flatMap(\.entries) {
            counts.all += 1
            if entry.isPrivate { counts.locked += 1 }
            switch entry.feel {
            case .good: counts.good += 1
            case .okay: counts.okay += 1
            case .heavy: counts.heavy += 1
            case .unrecognized, nil: break
            }
        }
        return counts
    }

    // MARK: Worked on

    /// One row per project, by time, the short ones and anything beyond six rows behind a line.
    public func workedOn(_ held: [MeHeld]) -> MeWorkedOn {
        var order: [String] = []
        var topics: [String: Int] = [:]
        var minutes: [String: Int] = [:]
        var phases: [String: [MeHeldPhase]] = [:]
        for entry in held {
            let name = entry.project ?? MeHeld.untitled
            if topics[name] == nil { order.append(name) }
            let own = entry.phases.isEmpty ? [MeHeldPhase(name: entry.label, minutes: entry.minutes)] : entry.phases
            topics[name, default: 0] += own.count
            minutes[name, default: 0] += entry.totalMinutes ?? 0
            phases[name, default: []].append(contentsOf: own)
        }
        var projects: [MeWorkedProject] = []
        for name in order {
            projects.append(
                MeWorkedProject(
                    name: name, topics: topics[name] ?? 0, minutes: minutes[name] ?? 0, phases: phases[name] ?? []))
        }
        projects.sort { left, right in
            left.minutes != right.minutes ? left.minutes > right.minutes : left.name < right.name
        }
        let long = projects.filter { $0.minutes >= MeWorkedOn.shortMinutes }
        let short = projects.filter { $0.minutes < MeWorkedOn.shortMinutes }
        let shown = Array(long.prefix(MeWorkedOn.shownRows))
        return MeWorkedOn(shown: shown, rest: Array(long.dropFirst(MeWorkedOn.shownRows)) + short)
    }

    /// `3 topics · 1 h 45`.
    public func workedLine(_ project: MeWorkedProject) -> String {
        let topics = "\(project.topics) topic\(project.topics == 1 ? "" : "s")"
        let time = duration(seconds: project.minutes * 60) ?? ""
        return "\(topics) · \(time)"
    }
}
