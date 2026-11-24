import Foundation

/// Swift port of the shapes `pai-cloud` serves under `/api/me/`: the self-reports of the diary and
/// the overview the Me screens draw. `pai-cloud` owns this contract; this file mirrors it.
///
/// Every field a source can be missing is optional or defaulted: a source that fails nulls its
/// fields and the route still answers 200, so a screen decodes what is there and hides the rest.

/// How a day felt, in the person's own pick. Three values, never a scale.
public enum SelfReportFeel: LenientWireEnum, CaseIterable {
    case heavy, okay, good
    case unrecognized(String)

    public static let knownValues: [String: SelfReportFeel] = ["heavy": .heavy, "okay": .okay, "good": .good]

    /// The three faces a composer offers, in the order they are drawn.
    public static var allCases: [SelfReportFeel] { [.heavy, .okay, .good] }

    /// What goes on the wire; nil for a value this build does not know.
    public var wire: String? {
        switch self {
        case .heavy: "heavy"
        case .okay: "okay"
        case .good: "good"
        case .unrecognized: nil
        }
    }
}

/// Where an entry was written.
public enum SelfReportSource: LenientWireEnum {
    case ios, web, computer, watch, day, session
    case unrecognized(String)

    public static let knownValues: [String: SelfReportSource] = [
        "ios": .ios, "web": .web, "computer": .computer, "watch": .watch, "day": .day, "session": .session,
    ]
}

/// A Garmin activity the server found around an entry's time. Computed at read time, never stored.
public struct SelfReportActivityContext: Decodable, Sendable, Equatable {
    public enum Relation: LenientWireEnum {
        case during, after
        case unrecognized(String)

        public static let knownValues: [String: Relation] = ["during": .during, "after": .after]
    }

    public let type: String?
    public let name: String?
    public let emoji: String?
    public let relation: Relation
    public let startAt: String?
    public let durationS: Int?

    public init(
        type: String? = nil, name: String? = nil, emoji: String? = nil, relation: Relation, startAt: String? = nil,
        durationS: Int? = nil
    ) {
        self.type = type
        self.name = name
        self.emoji = emoji
        self.relation = relation
        self.startAt = startAt
        self.durationS = durationS
    }

    enum CodingKeys: String, CodingKey {
        case type, name, emoji, relation
        case startAt = "start_at"
        case durationS = "duration_s"
    }
}

public struct SelfReportContext: Decodable, Sendable, Equatable {
    public let activity: SelfReportActivityContext?

    public init(activity: SelfReportActivityContext? = nil) { self.activity = activity }
}

/// One diary entry. `text` is nil for a face-only entry and for one the server redacted.
public struct SelfReport: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    /// The moment the entry is about, the server's string; read through ``IsoTimestamp``.
    public let at: String
    public let createdAt: String?
    public let editedAt: String?
    public let text: String?
    public let feel: SelfReportFeel?
    public let isPrivate: Bool
    public let redacted: Bool
    public let source: SelfReportSource?
    public let sessionId: String?
    public let sessionTitle: String?
    public let context: SelfReportContext?

    public init(
        id: String, at: String, createdAt: String? = nil, editedAt: String? = nil, text: String? = nil,
        feel: SelfReportFeel? = nil, isPrivate: Bool = false, redacted: Bool = false,
        source: SelfReportSource? = nil, sessionId: String? = nil, sessionTitle: String? = nil,
        context: SelfReportContext? = nil
    ) {
        self.id = id
        self.at = at
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.text = text
        self.feel = feel
        self.isPrivate = isPrivate
        self.redacted = redacted
        self.source = source
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case id, at, text, feel, redacted, source, context
        case createdAt = "created_at"
        case editedAt = "edited_at"
        case isPrivate = "private"
        case sessionId = "session_id"
        case sessionTitle = "session_title"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        at = try container.decode(String.self, forKey: .at)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        editedAt = try container.decodeIfPresent(String.self, forKey: .editedAt)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        feel = try container.decodeIfPresent(SelfReportFeel.self, forKey: .feel)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        redacted = try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false
        source = try container.decodeIfPresent(SelfReportSource.self, forKey: .source)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        sessionTitle = try container.decodeIfPresent(String.self, forKey: .sessionTitle)
        context = try container.decodeIfPresent(SelfReportContext.self, forKey: .context)
    }

    /// The moment as a date; nil only for a string no parser reads.
    public var date: Date? { IsoTimestamp.date(from: at) }

    /// Whether anything was written beyond a face.
    public var hasWords: Bool { !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

/// `GET /api/me/self-reports`: a page, and the cursor for the next one when this page was full.
public struct SelfReportPage: Decodable, Sendable, Equatable {
    public let selfReports: [SelfReport]
    public let nextBefore: String?

    public init(selfReports: [SelfReport], nextBefore: String? = nil) {
        self.selfReports = selfReports
        self.nextBefore = nextBefore
    }

    enum CodingKeys: String, CodingKey {
        case selfReports = "self_reports"
        case nextBefore = "next_before"
    }
}

// MARK: Overview

public enum MeSourceStatus: LenientWireEnum {
    case ok, unavailable, notConfigured
    case unrecognized(String)

    public static let knownValues: [String: MeSourceStatus] = [
        "ok": .ok, "unavailable": .unavailable, "not_configured": .notConfigured,
    ]
}

public struct MeSource: Decodable, Sendable, Equatable {
    public let status: MeSourceStatus
    public let asOf: String?

    public init(status: MeSourceStatus, asOf: String? = nil) {
        self.status = status
        self.asOf = asOf
    }

    enum CodingKeys: String, CodingKey {
        case status
        case asOf = "as_of"
    }
}

public struct MeSources: Decodable, Sendable, Equatable {
    public let garmin: MeSource?
    public let plan: MeSource?
    public let calendar: MeSource?

    public init(garmin: MeSource? = nil, plan: MeSource? = nil, calendar: MeSource? = nil) {
        self.garmin = garmin
        self.plan = plan
        self.calendar = calendar
    }

    /// The calendar row exists only while the source answers; an older server that does not
    /// mention it, and "not configured", both hide it.
    public var calendarConnected: Bool {
        guard let calendar else { return false }
        if case .ok = calendar.status { return true }
        return false
    }

    /// Garmin rows exist only for a source that is connected: "not configured" hides them, and so
    /// does a source the server did not mention.
    public var garminConnected: Bool {
        guard let garmin else { return false }
        if case .notConfigured = garmin.status { return false }
        return true
    }
}

public struct MeBody: Decodable, Sendable, Equatable {
    public let sleepSeconds: Int?
    public let sleepScore: Int?
    public let wakeAt: String?
    public let bodyBatteryWake: Int?
    public let readiness: Int?
    public let hrvStatus: String?

    public init(
        sleepSeconds: Int? = nil, sleepScore: Int? = nil, wakeAt: String? = nil, bodyBatteryWake: Int? = nil,
        readiness: Int? = nil, hrvStatus: String? = nil
    ) {
        self.sleepSeconds = sleepSeconds
        self.sleepScore = sleepScore
        self.wakeAt = wakeAt
        self.bodyBatteryWake = bodyBatteryWake
        self.readiness = readiness
        self.hrvStatus = hrvStatus
    }

    enum CodingKeys: String, CodingKey {
        case sleepSeconds = "sleep_seconds"
        case sleepScore = "sleep_score"
        case wakeAt = "wake_at"
        case bodyBatteryWake = "body_battery_wake"
        case readiness
        case hrvStatus = "hrv_status"
    }
}

public struct MeActivity: Decodable, Sendable, Equatable {
    public let type: String?
    public let name: String?
    public let emoji: String?
    public let startAt: String?
    public let durationS: Int?
    public let distanceM: Double?

    public init(
        type: String? = nil, name: String? = nil, emoji: String? = nil, startAt: String? = nil,
        durationS: Int? = nil, distanceM: Double? = nil
    ) {
        self.type = type
        self.name = name
        self.emoji = emoji
        self.startAt = startAt
        self.durationS = durationS
        self.distanceM = distanceM
    }

    enum CodingKeys: String, CodingKey {
        case type, name, emoji
        case startAt = "start_at"
        case durationS = "duration_s"
        case distanceM = "distance_m"
    }
}

public struct MePai: Decodable, Sendable, Equatable {
    public let messages: Int
    public let sessions: Int?
    public let firstMessageAt: String?
    public let lastMessageAt: String?
    public let overnightAgentMinutes: Int?

    public init(
        messages: Int, sessions: Int? = nil, firstMessageAt: String? = nil, lastMessageAt: String? = nil,
        overnightAgentMinutes: Int? = nil
    ) {
        self.messages = messages
        self.sessions = sessions
        self.firstMessageAt = firstMessageAt
        self.lastMessageAt = lastMessageAt
        self.overnightAgentMinutes = overnightAgentMinutes
    }

    enum CodingKeys: String, CodingKey {
        case messages, sessions
        case firstMessageAt = "first_message_at"
        case lastMessageAt = "last_message_at"
        case overnightAgentMinutes = "overnight_agent_minutes"
    }
}

public struct MePlan: Decodable, Sendable, Equatable {
    public let appetite: String?
    public let planned: Int?
    public let done: Int?
    public let added: Int?

    public init(appetite: String? = nil, planned: Int? = nil, done: Int? = nil, added: Int? = nil) {
        self.appetite = appetite
        self.planned = planned
        self.done = done
        self.added = added
    }
}

/// One phase of a project a day held; only the day route fills `summary`.
public struct MeHeldPhase: Decodable, Sendable, Equatable {
    public let name: String
    public let summary: String?
    public let minutes: Int?
    public let summaryStale: Bool

    public init(name: String, summary: String? = nil, minutes: Int? = nil, summaryStale: Bool = false) {
        self.name = name
        self.summary = summary
        self.minutes = minutes
        self.summaryStale = summaryStale
    }

    enum CodingKeys: String, CodingKey {
        case name, summary, minutes
        case summaryStale = "summary_stale"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        minutes = try container.decodeIfPresent(Int.self, forKey: .minutes)
        summaryStale = try container.decodeIfPresent(Bool.self, forKey: .summaryStale) ?? false
    }
}

/// What a day held at work: names and durations in the overview (`label`, `minutes`), the phases
/// with their summaries in the day route.
public struct MeHeld: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { project }

    public let project: String
    public let label: String?
    public let minutes: Int?
    public let phases: [MeHeldPhase]

    public init(project: String, label: String? = nil, minutes: Int? = nil, phases: [MeHeldPhase] = []) {
        self.project = project
        self.label = label
        self.minutes = minutes
        self.phases = phases
    }

    enum CodingKeys: String, CodingKey { case project, label, minutes, phases }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(String.self, forKey: .project)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        minutes = try container.decodeIfPresent(Int.self, forKey: .minutes)
        phases = try container.decodeIfPresent([MeHeldPhase].self, forKey: .phases) ?? []
    }

    /// The chip's name: the phase label when the overview sent one, else the project.
    public var title: String { label ?? project }

    /// Minutes of the project: its own figure, or what its phases add up to in the day route.
    public var totalMinutes: Int? {
        if let minutes { return minutes }
        let sum = phases.compactMap(\.minutes).reduce(0, +)
        return phases.isEmpty ? nil : sum
    }
}

/// A calendar event on a day. `startAt`/`endAt` are the server's strings (read through
/// ``IsoTimestamp``); an all-day event spans Berlin midnight to the midnight after its last day.
public struct MeEvent: Decodable, Sendable, Equatable {
    public let title: String
    public let startAt: String?
    public let endAt: String?
    public let allDay: Bool
    public let calendar: String?

    public init(
        title: String, startAt: String? = nil, endAt: String? = nil, allDay: Bool = false, calendar: String? = nil
    ) {
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.calendar = calendar
    }

    enum CodingKeys: String, CodingKey {
        case title, calendar
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        startAt = try container.decodeIfPresent(String.self, forKey: .startAt)
        endAt = try container.decodeIfPresent(String.self, forKey: .endAt)
        allDay = try container.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        calendar = try container.decodeIfPresent(String.self, forKey: .calendar)
    }
}

/// One day of the overview, and the day route's answer too. In the overview `entries` are the
/// dots only (no text) and `held` carries names and durations; the day route fills both fully.
public struct MeDay: Decodable, Sendable, Equatable, Identifiable {
    public let date: String
    public let final: Bool
    public let body: MeBody?
    public let activities: [MeActivity]
    /// Nil means no message that day.
    public let pai: MePai?
    public let wakeToFirstMessageMin: Int?
    public let plan: MePlan?
    public let entries: [SelfReport]
    public let held: [MeHeld]
    /// Calendar events touching the day, sorted by start; empty whenever the source is not ok.
    public let events: [MeEvent]

    public var id: String { date }

    public init(
        date: String, final: Bool = true, body: MeBody? = nil, activities: [MeActivity] = [], pai: MePai? = nil,
        wakeToFirstMessageMin: Int? = nil, plan: MePlan? = nil, entries: [SelfReport] = [], held: [MeHeld] = [],
        events: [MeEvent] = []
    ) {
        self.date = date
        self.final = final
        self.body = body
        self.activities = activities
        self.pai = pai
        self.wakeToFirstMessageMin = wakeToFirstMessageMin
        self.plan = plan
        self.entries = entries
        self.held = held
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case date, final, body, activities, pai, plan, entries, held, events
        case wakeToFirstMessageMin = "wake_to_first_message_min"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        final = try container.decodeIfPresent(Bool.self, forKey: .final) ?? true
        body = try container.decodeIfPresent(MeBody.self, forKey: .body)
        activities = try container.decodeIfPresent([MeActivity].self, forKey: .activities) ?? []
        pai = try container.decodeIfPresent(MePai.self, forKey: .pai)
        wakeToFirstMessageMin = try container.decodeIfPresent(Int.self, forKey: .wakeToFirstMessageMin)
        plan = try container.decodeIfPresent(MePlan.self, forKey: .plan)
        entries = try container.decodeIfPresent([SelfReport].self, forKey: .entries) ?? []
        held = try container.decodeIfPresent([MeHeld].self, forKey: .held) ?? []
        events = try container.decodeIfPresent([MeEvent].self, forKey: .events) ?? []
    }
}

/// A life note linked from Today.
public struct MeNote: Decodable, Sendable, Equatable, Identifiable {
    public let key: String
    public let title: String
    public let noteId: String

    public var id: String { key }

    public init(key: String, title: String, noteId: String) {
        self.key = key
        self.title = title
        self.noteId = noteId
    }

    enum CodingKeys: String, CodingKey {
        case key, title
        case noteId = "note_id"
    }
}

/// The latest weekly review, when one newer than seven days exists.
public struct MeReview: Decodable, Sendable, Equatable {
    public let title: String
    public let noteId: String
    public let week: Int?
    /// The compass-talk session the latest review names; nil hides the Compass button.
    public let compassSessionId: String?

    public init(title: String, noteId: String, week: Int? = nil, compassSessionId: String? = nil) {
        self.title = title
        self.noteId = noteId
        self.week = week
        self.compassSessionId = compassSessionId
    }

    enum CodingKeys: String, CodingKey {
        case title, week
        case noteId = "note_id"
        case compassSessionId = "compass_session_id"
    }
}

/// `GET /api/me/overview`: the days oldest first, plus what Today shows besides them.
public struct MeOverview: Decodable, Sendable, Equatable {
    public let generatedAt: String?
    public let timezone: String
    public let today: String
    public let sources: MeSources
    public let days: [MeDay]
    public let recentEntries: [SelfReport]
    public let lookingBack: SelfReport?
    public let notes: [MeNote]
    public let review: MeReview?

    public init(
        generatedAt: String? = nil, timezone: String = "Europe/Berlin", today: String, sources: MeSources = MeSources(),
        days: [MeDay], recentEntries: [SelfReport] = [], lookingBack: SelfReport? = nil, notes: [MeNote] = [],
        review: MeReview? = nil
    ) {
        self.generatedAt = generatedAt
        self.timezone = timezone
        self.today = today
        self.sources = sources
        self.days = days
        self.recentEntries = recentEntries
        self.lookingBack = lookingBack
        self.notes = notes
        self.review = review
    }

    enum CodingKeys: String, CodingKey {
        case timezone, today, sources, days, notes, review
        case generatedAt = "generated_at"
        case recentEntries = "recent_entries"
        case lookingBack = "looking_back"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone) ?? "Europe/Berlin"
        today = try container.decode(String.self, forKey: .today)
        sources = try container.decodeIfPresent(MeSources.self, forKey: .sources) ?? MeSources()
        days = try container.decode([MeDay].self, forKey: .days)
        recentEntries = try container.decodeIfPresent([SelfReport].self, forKey: .recentEntries) ?? []
        lookingBack = try container.decodeIfPresent(SelfReport.self, forKey: .lookingBack)
        notes = try container.decodeIfPresent([MeNote].self, forKey: .notes) ?? []
        review = try container.decodeIfPresent(MeReview.self, forKey: .review)
    }
}
