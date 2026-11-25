import Foundation

/// Swift port of the reminder contract (`GET /api/reminders` and its siblings): something the
/// owner asked to be told, fired by a place, a Home Assistant event or a script. Reminders are
/// written by an agent from a sentence; this app lists, tests, pauses and deletes them.

/// Where a reminder is in its life.
public enum ReminderState: LenientWireEnum {
    case armed, paused, failing, fired, expired
    case unrecognized(String)

    public static let knownValues: [String: ReminderState] = [
        "armed": .armed, "paused": .paused, "failing": .failing, "fired": .fired, "expired": .expired,
    ]
}

/// Whether a reminder fires once or again after a cooldown.
public enum ReminderMode: LenientWireEnum {
    case once, repeating
    case unrecognized(String)

    public static let knownValues: [String: ReminderMode] = ["once": .once, "repeat": .repeating]
}

/// What wakes a reminder.
public enum ReminderTriggerKind: LenientWireEnum {
    case poll, place, ha, listen
    case unrecognized(String)

    public static let knownValues: [String: ReminderTriggerKind] = [
        "poll": .poll, "place": .place, "ha": .ha, "listen": .listen,
    ]
}

/// The trigger object. Only the fields of its own kind are present.
public struct ReminderTrigger: Decodable, Sendable, Equatable {
    public let kind: ReminderTriggerKind
    /// `poll`: seconds between two checks.
    public let intervalSeconds: Int?
    /// `place`: the named place and `enter` or `exit`, with an optional dwell in seconds.
    public let place: String?
    public let on: String?
    public let dwellSeconds: Int?
    /// `ha`: the entity and the state change it waits for.
    public let entityId: String?
    public let from: String?
    public let to: String?
    public let attribute: String?

    enum CodingKeys: String, CodingKey {
        case kind, place, on, from, to, attribute
        case intervalSeconds = "interval_s"
        case dwellSeconds = "dwell_s"
        case entityId = "entity_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(ReminderTriggerKind.self, forKey: .kind)) ?? .unrecognized("")
        intervalSeconds = container.decodeLenientInt(forKey: .intervalSeconds)
        dwellSeconds = container.decodeLenientInt(forKey: .dwellSeconds)
        place = try? container.decodeIfPresent(String.self, forKey: .place)
        on = try? container.decodeIfPresent(String.self, forKey: .on)
        entityId = try? container.decodeIfPresent(String.self, forKey: .entityId)
        from = try? container.decodeIfPresent(String.self, forKey: .from)
        to = try? container.decodeIfPresent(String.self, forKey: .to)
        attribute = try? container.decodeIfPresent(String.self, forKey: .attribute)
    }

    public init(
        kind: ReminderTriggerKind, intervalSeconds: Int? = nil, place: String? = nil, on: String? = nil,
        dwellSeconds: Int? = nil, entityId: String? = nil, from: String? = nil, to: String? = nil,
        attribute: String? = nil
    ) {
        self.kind = kind
        self.intervalSeconds = intervalSeconds
        self.place = place
        self.on = on
        self.dwellSeconds = dwellSeconds
        self.entityId = entityId
        self.from = from
        self.to = to
        self.attribute = attribute
    }
}

/// `condition_place`: hold a fire unless the owner is (or is not) in that place.
public struct ReminderConditionPlace: Decodable, Sendable, Equatable {
    public let place: String
    public let inside: Bool

    public init(place: String, inside: Bool) {
        self.place = place
        self.inside = inside
    }
}

/// `active_window`: the days and clock span a reminder may fire in, in its own timezone.
public struct ReminderActiveWindow: Decodable, Sendable, Equatable {
    /// ISO weekdays, 1 is Monday; nil means every day.
    public let days: [Int]?
    public let from: String?
    public let to: String?

    enum CodingKeys: String, CodingKey { case days, from, to }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try? container.decodeIfPresent([Int].self, forKey: .days)
        from = try? container.decodeIfPresent(String.self, forKey: .from)
        to = try? container.decodeIfPresent(String.self, forKey: .to)
    }

    public init(days: [Int]?, from: String?, to: String?) {
        self.days = days
        self.from = from
        self.to = to
    }
}

/// What the last check of a script reminder came to.
public struct ReminderLastResult: Decodable, Sendable, Equatable {
    public let ok: Bool?
    public let fire: Bool?
    public let error: String?
    public let exitCode: Int?
    public let cpuMs: Int?
    public let durationMs: Int?
    public let stdoutTail: String?
    public let stderrTail: String?

    enum CodingKeys: String, CodingKey {
        case ok, fire, error
        case exitCode = "exit_code"
        case cpuMs = "cpu_ms"
        case durationMs = "duration_ms"
        case stdoutTail = "stdout_tail"
        case stderrTail = "stderr_tail"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try? container.decodeIfPresent(Bool.self, forKey: .ok)
        fire = try? container.decodeIfPresent(Bool.self, forKey: .fire)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        exitCode = container.decodeLenientInt(forKey: .exitCode)
        cpuMs = container.decodeLenientInt(forKey: .cpuMs)
        durationMs = container.decodeLenientInt(forKey: .durationMs)
        stdoutTail = try? container.decodeIfPresent(String.self, forKey: .stdoutTail)
        stderrTail = try? container.decodeIfPresent(String.self, forKey: .stderrTail)
    }

    public init(
        ok: Bool?, fire: Bool?, error: String?, exitCode: Int?, cpuMs: Int?, durationMs: Int?,
        stdoutTail: String?, stderrTail: String?
    ) {
        self.ok = ok
        self.fire = fire
        self.error = error
        self.exitCode = exitCode
        self.cpuMs = cpuMs
        self.durationMs = durationMs
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }
}

/// One line of a reminder's history. `detail` is free-form on the wire; the strings a reader
/// wants (why it failed or paused, what it fired for) are lifted out of it.
public struct ReminderEvent: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let at: String
    /// `created`, `edited`, `tested`, `fired`, `failed`, `recovered`, `paused`, `resumed`, `expired`.
    public let kind: String
    /// The first of `message`, `reason`, `note` or `task` the detail holds.
    public let note: String?

    enum CodingKeys: String, CodingKey { case id, at, kind, detail }

    private struct DetailKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLenientInt(forKey: .id) ?? 0
        at = (try? container.decode(String.self, forKey: .at)) ?? ""
        kind = (try? container.decode(String.self, forKey: .kind)) ?? ""
        var found: String?
        if let detail = try? container.nestedContainer(keyedBy: DetailKey.self, forKey: .detail) {
            for name in ["message", "reason", "note", "task"] {
                guard let key = DetailKey(stringValue: name),
                    let text = try? detail.decodeIfPresent(String.self, forKey: key), !text.isEmpty
                else { continue }
                found = text
                break
            }
        }
        note = found
    }

    public init(id: Int, at: String, kind: String, note: String?) {
        self.id = id
        self.at = at
        self.kind = kind
        self.note = note
    }
}

/// One reminder: the list shape, and with `events` and the fields after them the detail shape.
public struct Reminder: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let title: String
    public let trigger: ReminderTrigger
    public let mode: ReminderMode
    public let state: ReminderState
    /// `user` or `budget` while paused.
    public let pausedReason: String?
    public let lastCheckAt: String?
    public let nextCheckAt: String?
    public let lastFiredAt: String?
    public let firedCount: Int
    public let expiresAt: String?
    public let consecutiveFailures: Int
    public let cpuMsToday: Int
    public let hasScript: Bool

    // Detail only.
    public let body: String?
    public let conditionPlace: ReminderConditionPlace?
    public let scriptSource: String?
    public let scriptRuntime: String?
    public let cooldownSeconds: Int?
    public let activeWindow: ReminderActiveWindow?
    public let timezone: String?
    public let lastResult: ReminderLastResult?
    public let events: [ReminderEvent]?

    enum CodingKeys: String, CodingKey {
        case id, name, title, trigger, mode, state, body, timezone, events
        case pausedReason = "paused_reason"
        case lastCheckAt = "last_check_at"
        case nextCheckAt = "next_check_at"
        case lastFiredAt = "last_fired_at"
        case firedCount = "fired_count"
        case expiresAt = "expires_at"
        case consecutiveFailures = "consecutive_failures"
        case cpuMsToday = "cpu_ms_today"
        case hasScript = "has_script"
        case conditionPlace = "condition_place"
        case scriptSource = "script_source"
        case scriptRuntime = "script_runtime"
        case cooldownSeconds = "cooldown_s"
        case activeWindow = "active_window"
        case lastResult = "last_result"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        title = (try? container.decode(String.self, forKey: .title)) ?? name
        trigger =
            (try? container.decode(ReminderTrigger.self, forKey: .trigger))
            ?? ReminderTrigger(kind: .unrecognized(""))
        mode = (try? container.decode(ReminderMode.self, forKey: .mode)) ?? .once
        state = (try? container.decode(ReminderState.self, forKey: .state)) ?? .unrecognized("")
        pausedReason = try? container.decodeIfPresent(String.self, forKey: .pausedReason)
        lastCheckAt = try? container.decodeIfPresent(String.self, forKey: .lastCheckAt)
        nextCheckAt = try? container.decodeIfPresent(String.self, forKey: .nextCheckAt)
        lastFiredAt = try? container.decodeIfPresent(String.self, forKey: .lastFiredAt)
        firedCount = container.decodeLenientInt(forKey: .firedCount) ?? 0
        expiresAt = try? container.decodeIfPresent(String.self, forKey: .expiresAt)
        consecutiveFailures = container.decodeLenientInt(forKey: .consecutiveFailures) ?? 0
        cpuMsToday = container.decodeLenientInt(forKey: .cpuMsToday) ?? 0
        hasScript = (try? container.decode(Bool.self, forKey: .hasScript)) ?? false
        body = try? container.decodeIfPresent(String.self, forKey: .body)
        conditionPlace = try? container.decodeIfPresent(ReminderConditionPlace.self, forKey: .conditionPlace)
        scriptSource = try? container.decodeIfPresent(String.self, forKey: .scriptSource)
        scriptRuntime = try? container.decodeIfPresent(String.self, forKey: .scriptRuntime)
        cooldownSeconds = container.decodeLenientInt(forKey: .cooldownSeconds)
        activeWindow = try? container.decodeIfPresent(ReminderActiveWindow.self, forKey: .activeWindow)
        timezone = try? container.decodeIfPresent(String.self, forKey: .timezone)
        lastResult = try? container.decodeIfPresent(ReminderLastResult.self, forKey: .lastResult)
        events = try? container.decodeIfPresent([ReminderEvent].self, forKey: .events)
    }

    public init(
        id: String, name: String, title: String, trigger: ReminderTrigger, mode: ReminderMode = .once,
        state: ReminderState = .armed, pausedReason: String? = nil, lastCheckAt: String? = nil,
        nextCheckAt: String? = nil, lastFiredAt: String? = nil, firedCount: Int = 0, expiresAt: String? = nil,
        consecutiveFailures: Int = 0, cpuMsToday: Int = 0, hasScript: Bool = false, body: String? = nil,
        conditionPlace: ReminderConditionPlace? = nil, scriptSource: String? = nil, scriptRuntime: String? = nil,
        cooldownSeconds: Int? = nil, activeWindow: ReminderActiveWindow? = nil, timezone: String? = nil,
        lastResult: ReminderLastResult? = nil, events: [ReminderEvent]? = nil
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.trigger = trigger
        self.mode = mode
        self.state = state
        self.pausedReason = pausedReason
        self.lastCheckAt = lastCheckAt
        self.nextCheckAt = nextCheckAt
        self.lastFiredAt = lastFiredAt
        self.firedCount = firedCount
        self.expiresAt = expiresAt
        self.consecutiveFailures = consecutiveFailures
        self.cpuMsToday = cpuMsToday
        self.hasScript = hasScript
        self.body = body
        self.conditionPlace = conditionPlace
        self.scriptSource = scriptSource
        self.scriptRuntime = scriptRuntime
        self.cooldownSeconds = cooldownSeconds
        self.activeWindow = activeWindow
        self.timezone = timezone
        self.lastResult = lastResult
        self.events = events
    }
}

/// `GET /api/reminders`.
public struct ReminderListResponse: Decodable, Sendable, Equatable {
    public let reminders: [Reminder]

    public init(reminders: [Reminder]) {
        self.reminders = reminders
    }
}

/// `POST /api/reminders/{id}/test`: what the script said and whether a fire would notify.
public struct ReminderTestResult: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let fire: Bool?
    public let title: String
    public let body: String
    public let wouldNotify: Bool
    public let reasonNot: String?
    public let error: String?
    public let exitCode: Int?
    public let stdoutTail: String
    public let stderrTail: String
    public let cpuMs: Int?
    public let durationMs: Int?
    public let notified: Bool

    enum CodingKeys: String, CodingKey {
        case ok, fire, title, body, error, notified
        case wouldNotify = "would_notify"
        case reasonNot = "reason_not"
        case exitCode = "exit_code"
        case stdoutTail = "stdout_tail"
        case stderrTail = "stderr_tail"
        case cpuMs = "cpu_ms"
        case durationMs = "duration_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container.decode(Bool.self, forKey: .ok)) ?? false
        fire = try? container.decodeIfPresent(Bool.self, forKey: .fire)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        wouldNotify = (try? container.decode(Bool.self, forKey: .wouldNotify)) ?? false
        reasonNot = try? container.decodeIfPresent(String.self, forKey: .reasonNot)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        exitCode = container.decodeLenientInt(forKey: .exitCode)
        stdoutTail = (try? container.decode(String.self, forKey: .stdoutTail)) ?? ""
        stderrTail = (try? container.decode(String.self, forKey: .stderrTail)) ?? ""
        cpuMs = container.decodeLenientInt(forKey: .cpuMs)
        durationMs = container.decodeLenientInt(forKey: .durationMs)
        notified = (try? container.decode(Bool.self, forKey: .notified)) ?? false
    }

    public init(
        ok: Bool, fire: Bool?, title: String, body: String, wouldNotify: Bool, reasonNot: String?, error: String?,
        exitCode: Int?, stdoutTail: String, stderrTail: String, cpuMs: Int?, durationMs: Int?, notified: Bool
    ) {
        self.ok = ok
        self.fire = fire
        self.title = title
        self.body = body
        self.wouldNotify = wouldNotify
        self.reasonNot = reasonNot
        self.error = error
        self.exitCode = exitCode
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
        self.cpuMs = cpuMs
        self.durationMs = durationMs
        self.notified = notified
    }
}
