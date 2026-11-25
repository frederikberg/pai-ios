import Foundation

/// Pure wording for the reminder list and detail, kept out of the views so it is provable on Linux.
public enum ReminderDisplay {
    public enum Tone: Equatable, Sendable {
        case ok, muted, warning, error
    }

    /// What wakes the reminder, as a short phrase: `arrive Work`, `leave Work after 5 min`,
    /// `check every 15 min`, `binary_sensor.front_door becomes on`, `listens for events`.
    public static func triggerLine(_ trigger: ReminderTrigger) -> String {
        switch trigger.kind {
        case .place:
            let verb = trigger.on == "exit" ? "leave" : "arrive at"
            var line = "\(verb) \(trigger.place ?? "a place")"
            if let dwell = trigger.dwellSeconds, dwell > 0 { line += " after \(duration(seconds: dwell))" }
            return line
        case .ha:
            let entity = trigger.entityId ?? "a Home Assistant entity"
            var line = entity
            if let attribute = trigger.attribute { line += " \(attribute)" }
            if let to = trigger.to {
                line += " becomes \(to)"
            } else {
                line += " changes"
            }
            if let from = trigger.from { line += " from \(from)" }
            return line
        case .poll:
            guard let interval = trigger.intervalSeconds else { return "checks on a schedule" }
            return "checks every \(duration(seconds: interval))"
        case .listen:
            return "listens for events"
        case .unrecognized(let raw):
            return raw.isEmpty ? "unknown trigger" : "\(raw) trigger"
        }
    }

    /// The list row's second line: the trigger and how often it fires.
    public static func summaryLine(_ reminder: Reminder) -> String {
        var parts = [triggerLine(reminder.trigger)]
        switch reminder.mode {
        case .once: parts.append("once")
        case .repeating:
            if let cooldown = reminder.cooldownSeconds {
                parts.append("repeats, at most every \(duration(seconds: cooldown))")
            } else {
                parts.append("repeats")
            }
        case .unrecognized(let raw): parts.append(raw)
        }
        return parts.joined(separator: " · ")
    }

    /// The state in one word, with why when a pause has a reason.
    public static func stateLabel(_ reminder: Reminder) -> String {
        switch reminder.state {
        case .armed: return "armed"
        case .paused: return reminder.pausedReason == "budget" ? "paused until midnight" : "paused"
        case .failing: return "failing"
        case .fired: return "fired"
        case .expired: return "expired"
        case .unrecognized(let raw): return raw.isEmpty ? "unknown" : raw
        }
    }

    public static func stateTone(_ reminder: Reminder) -> Tone {
        switch reminder.state {
        case .armed: return .ok
        case .paused, .fired, .expired: return .muted
        case .failing: return .error
        case .unrecognized: return .warning
        }
    }

    /// `last checked 14:05` / `fired 3 times, last 09:12`: what the reminder has done lately.
    public static func activityLine(_ reminder: Reminder) -> String? {
        var parts: [String] = []
        if reminder.firedCount > 0 {
            var fired = "fired \(reminder.firedCount) time\(reminder.firedCount == 1 ? "" : "s")"
            if let last = berlin(reminder.lastFiredAt) { fired += ", last \(last)" }
            parts.append(fired)
        }
        if let checked = berlin(reminder.lastCheckAt) { parts.append("checked \(checked)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// When a once-reminder gives up, for the detail.
    public static func expiryLine(_ reminder: Reminder) -> String? {
        guard reminder.state == .armed || reminder.state == .failing, let expires = berlin(reminder.expiresAt)
        else { return nil }
        return "expires \(expires)"
    }

    /// The condition and the window, as the sentences they are.
    public static func limitLines(_ reminder: Reminder) -> [String] {
        var lines: [String] = []
        if let condition = reminder.conditionPlace {
            lines.append("only while \(condition.inside ? "inside" : "outside") \(condition.place)")
        }
        if let window = reminder.activeWindow, let from = window.from, let to = window.to {
            var line = "only \(from)–\(to)"
            if let days = window.days, !days.isEmpty, days.count < 7 { line += " on \(dayNames(days))" }
            lines.append(line)
        }
        return lines
    }

    /// One history line: `09:12 fired`, `09:00 failed: HTTP 500`.
    public static func eventLine(_ event: ReminderEvent) -> String {
        let when = berlin(event.at) ?? event.at
        guard let note = event.note else { return "\(when) \(event.kind)" }
        return "\(when) \(event.kind): \(note)"
    }

    /// The test result as the few sentences a person wants: whether it would notify and why not.
    public static func testSummary(_ result: ReminderTestResult) -> String {
        if let error = result.error { return "The check failed: \(error)" }
        if !result.ok { return "The check did not run cleanly." }
        if result.notified { return "Sent a test notification." }
        if result.wouldNotify { return "Would notify: \(result.title)" }
        if let reason = result.reasonNot { return "Would not notify now: \(reason)" }
        return result.fire == true ? "The check says to fire." : "The check says nothing to report yet."
    }

    private static func berlin(_ wire: String?) -> String? {
        guard let wire, let date = IsoTimestamp.date(from: wire) else { return nil }
        return SchedulerRunDisplay.formatBerlin(ms: Int(date.timeIntervalSince1970 * 1000))
    }

    /// 90 is `90 s`, 300 is `5 min`, 3600 is `60 min`, 7200 is `2 h`, 259200 is `3 d`.
    static func duration(seconds: Int) -> String {
        if seconds < 120 { return "\(seconds) s" }
        if seconds < 7200 { return "\(seconds / 60) min" }
        if seconds < 172_800 { return "\(seconds / 3600) h" }
        return "\(seconds / 86_400) d"
    }

    private static func dayNames(_ days: [Int]) -> String {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return days.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: ", ")
    }
}
