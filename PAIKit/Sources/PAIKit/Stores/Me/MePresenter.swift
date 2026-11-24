import Foundation

/// How the Me screens word and measure what the server sent: grouping by the Berlin day, the
/// labels, the bar heights. Pure functions of the model, so the rules that break silently (a day
/// boundary, a missing value read as zero) are covered by tests and the views only draw.
public struct MePresenter: Sendable {
    public let calendar: Calendar

    /// `timeZone` is the overview's own zone name; an unknown name falls back to Berlin, the
    /// zone every day boundary of this app is drawn in.
    public init(timeZoneName: String = "Europe/Berlin") {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: timeZoneName) ?? TimeZone(identifier: "Europe/Berlin") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        self.calendar = calendar
    }

    // MARK: Days

    /// `yyyy-MM-dd` of the moment, as the wall clock of the zone reads.
    public func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of the day a key names; nil for a malformed key.
    public func date(forKey key: String) -> Date? {
        let pieces = key.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }

    /// The key `offset` days from `key`.
    public func shift(key: String, byDays offset: Int) -> String? {
        guard let start = date(forKey: key), let moved = calendar.date(byAdding: .day, value: offset, to: start)
        else { return nil }
        return dayKey(moved)
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// "17:30" on the 24-hour clock of the zone.
    public func clock(_ date: Date) -> String { format(date, "HH:mm") }

    public func clock(wire: String?) -> String? {
        guard let wire, let date = IsoTimestamp.date(from: wire) else { return nil }
        return clock(date)
    }

    public func weekdayLetter(key: String) -> String {
        guard let day = date(forKey: key) else { return "" }
        return String(format(day, "EEEEE"))
    }

    public func dayNumber(key: String) -> String {
        guard let day = date(forKey: key) else { return "" }
        return format(day, "d")
    }

    public func weekdayName(key: String) -> String {
        guard let day = date(forKey: key) else { return key }
        return format(day, "EEEE")
    }

    /// "24 November · week 48".
    public func dayHeaderCaption(key: String) -> String {
        guard let day = date(forKey: key) else { return key }
        let week = calendar.component(.weekOfYear, from: day)
        return "\(format(day, "d MMMM")) · week \(week)"
    }

    /// "Thursday 19 November".
    public func longDay(key: String) -> String {
        guard let day = date(forKey: key) else { return key }
        return format(day, "EEEE d MMMM")
    }

    /// "Tue 24 Nov".
    public func shortDay(key: String) -> String {
        guard let day = date(forKey: key) else { return key }
        return format(day, "EEE d MMM")
    }

    /// "11 – 24 November", or "28 October – 10 November" across a month.
    public func rangeTitle(from first: String, to last: String) -> String {
        guard let start = date(forKey: first), let end = date(forKey: last) else { return "" }
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let left = sameMonth ? format(start, "d") : format(start, "d MMMM")
        return "\(left) – \(format(end, "d MMMM"))"
    }

    // MARK: Diary

    /// A day of the diary: the entries of one Berlin day, newest first. Days without entries do
    /// not exist, so nothing marks a gap.
    public struct DiaryGroup: Equatable, Sendable, Identifiable {
        public let key: String
        public let title: String
        public let dateLabel: String
        public let entries: [SelfReport]
        public var id: String { key }
    }

    /// Groups by the Berlin day of each entry's moment, days and entries newest first.
    /// `todayKey` names "Today" and "Yesterday".
    public func groups(of entries: [SelfReport], todayKey: String) -> [DiaryGroup] {
        let dated: [(SelfReport, Date)] = entries.compactMap { entry in entry.date.map { (entry, $0) } }
        let sorted = dated.sorted { $0.1 > $1.1 }
        var order: [String] = []
        var byDay: [String: [SelfReport]] = [:]
        for (entry, date) in sorted {
            let key = dayKey(date)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(entry)
        }
        let yesterday = shift(key: todayKey, byDays: -1)
        return order.map { key in
            let title =
                key == todayKey ? "Today" : key == yesterday ? "Yesterday" : weekdayName(key: key)
            let label = date(forKey: key).map { format($0, "EEE d MMM") } ?? key
            return DiaryGroup(key: key, title: title, dateLabel: label, entries: byDay[key] ?? [])
        }
    }

    /// The meta line's relative-time text for an entry written about another moment than it was
    /// created: nothing, since the clock time is shown on the card itself.
    public func entryTime(_ entry: SelfReport) -> String {
        entry.date.map(clock) ?? ""
    }

    /// "during bouldering" / "after a ride": the context chip's words, nil when nothing honest is known.
    public func contextChip(_ entry: SelfReport) -> (emoji: String, text: String)? {
        if let activity = entry.context?.activity {
            let name = (activity.name ?? activity.type ?? "").lowercased()
            let emoji = activity.emoji ?? "•"
            switch activity.relation {
            case .during: return (emoji, name.isEmpty ? "during an activity" : "during \(name)")
            case .after: return (emoji, name.isEmpty ? "after an activity" : "after \(name)")
            case .unrecognized: return nil
            }
        }
        if let title = entry.sessionTitle, !title.isEmpty { return ("💬", title) }
        return nil
    }

    /// What an entry's words read as: dictated text carries the `stt-rec: ` marker (it tells a
    /// session the words came from speech), which the diary keeps in storage but never shows.
    /// `spoken` is true when the marker was there.
    public struct EntryWords: Equatable, Sendable {
        public let text: String?
        public let spoken: Bool
    }

    public func words(of entry: SelfReport) -> EntryWords {
        guard let raw = entry.text else { return EntryWords(text: nil, spoken: false) }
        let marker = VoiceRecordingResult.sttPrefix
        let spoken = raw.contains(marker)
        let cleaned = (spoken ? raw.replacingOccurrences(of: marker, with: "") : raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return EntryWords(text: cleaned.isEmpty ? nil : cleaned, spoken: spoken)
    }

    /// 🎙 spoken, ⌚ watch: only a source that is not plain typing gets a chip. Words that were
    /// dictated into the composer are spoken whatever the entry's source says.
    public func sourceChip(_ entry: SelfReport) -> (emoji: String, text: String)? {
        if words(of: entry).spoken { return ("🎙", "spoken") }
        switch entry.source {
        case .computer: return ("🎙", "spoken")
        case .watch: return ("⌚", "watch")
        default: return nil
        }
    }

    // MARK: Numbers and wording

    /// "7 h 35" from seconds; nil when there is no sleep figure. A zero is a figure.
    public func hoursMinutes(seconds: Int?) -> String? {
        guard let seconds else { return nil }
        let minutes = (seconds + 30) / 60
        return String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    /// "58 min" under an hour, "1 h 25" above.
    public func duration(seconds: Int?) -> String? {
        guard let seconds else { return nil }
        let minutes = (seconds + 30) / 60
        return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    /// "3 h" / "20 min" for the rounded durations on a "what the day held" chip.
    public func roundedMinutes(_ minutes: Int?) -> String? {
        guard let minutes else { return nil }
        if minutes < 60 { return "\(max(1, (minutes + 2) / 5 * 5)) min" }
        let halfHours = (minutes + 15) / 30
        return halfHours % 2 == 0 ? "\(halfHours / 2) h" : String(format: "%.1f h", Double(halfHours) / 2)
    }

    public func kilometres(meters: Double?) -> String? {
        guard let meters, meters > 0 else { return nil }
        let km = meters / 1000
        return km < 10 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
    }

    /// Height of a sleep bar: 5 pt an hour, nothing for a day with no figure.
    public func sleepBarHeight(seconds: Int?, pointsPerHour: Double = 5) -> Double? {
        guard let seconds else { return nil }
        return Double(seconds) / 3600 * pointsPerHour
    }

    /// "hours" of the selected sleep bar: "6.1".
    public func sleepHoursLabel(seconds: Int?) -> String? {
        guard let seconds else { return nil }
        return String(format: "%.1f", Double(seconds) / 3600)
    }

    /// The plan line of Today: "Plan · light day — 2 of 3 done, 1 added later"; nil without a plan.
    public func planLine(_ plan: MePlan?) -> String? {
        guard let plan else { return nil }
        var parts: [String] = []
        if let planned = plan.planned, let done = plan.done { parts.append("\(done) of \(planned) done") }
        if let added = plan.added, added > 0 { parts.append("\(added) added later") }
        let appetite = plan.appetite.map { "Plan · \($0)" } ?? "Plan"
        return parts.isEmpty ? appetite : "\(appetite) — \(parts.joined(separator: ", "))"
    }

    /// "Morning · first PAI message 77 min after waking", only when both times exist.
    public func morningLine(_ day: MeDay) -> String? {
        guard let minutes = day.wakeToFirstMessageMin else { return nil }
        return "Morning · first PAI message \(minutes) min after waking"
    }

    /// One bar's height share for the PAI row: 1.3 pt a message, capped.
    public func paiBarHeight(messages: Int, cap: Double = 52) -> Double {
        min(cap, max(4, Double(messages) * 1.3))
    }

    /// A calendar event as the screens write it: its title, a timed one with its start time in front.
    public func eventLine(_ event: MeEvent) -> String {
        guard !event.allDay, let time = clock(wire: event.startAt) else { return event.title }
        return "\(time) \(event.title)"
    }

    // MARK: This week

    /// The seven days ending at `todayKey` out of the overview's days, oldest first.
    public func week(of days: [MeDay], todayKey: String) -> [MeDay] {
        guard let index = days.firstIndex(where: { $0.date == todayKey }) else { return Array(days.suffix(7)) }
        let start = max(0, index - 6)
        return Array(days[start...index])
    }

    /// Faces of a day's entries for the grid: at most two, the rest as a count; a private entry
    /// without a face is a lock.
    public struct EntryMarks: Equatable, Sendable {
        public let faces: [SelfReportFeel]
        public let more: Int
        public let lock: Bool
    }

    public func marks(of entries: [SelfReport], maxFaces: Int = 2) -> EntryMarks {
        let faces = entries.compactMap(\.feel)
        let lock = entries.contains { $0.isPrivate && $0.feel == nil }
        return EntryMarks(faces: Array(faces.prefix(maxFaces)), more: max(0, faces.count - maxFaces), lock: lock)
    }
}

/// What the Me screens show and in which order: the person's body, life and diary come first and
/// the numbers about PAI below them. One home for the order, so a screen only draws it.
public enum MeLayout {
    /// The rows of the 14-day grid, top to bottom. The morning measure is not a grid row; it lives
    /// in the day's detail. Rows from Garmin exist only while it is connected.
    public enum GridRow: Equatable, Sendable {
        case diary, sleep, bodyBattery, movement, calendar, pai
    }

    /// Life rows follow the body rows; each exists only while its source is connected.
    public static func gridRows(garminConnected: Bool, calendarConnected: Bool = false) -> [GridRow] {
        var rows: [GridRow] = [.diary]
        if garminConnected { rows += [.sleep, .bodyBattery, .movement] }
        if calendarConnected { rows.append(.calendar) }
        rows.append(.pai)
        return rows
    }

    /// The blocks of the Today view, top to bottom.
    public enum TodaySection: Equatable, Sendable {
        case write, review, soFar, week, diary, lookingBack, pai, notes
    }

    public static func todaySections(for overview: MeOverview) -> [TodaySection] {
        var sections: [TodaySection] = [.write]
        if overview.review != nil { sections.append(.review) }
        sections += [.soFar, .week, .diary]
        if overview.lookingBack != nil { sections.append(.lookingBack) }
        sections.append(.pai)
        if !overview.notes.isEmpty { sections.append(.notes) }
        return sections
    }
}
