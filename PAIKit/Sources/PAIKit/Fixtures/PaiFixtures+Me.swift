import Foundation

/// `GET /api/me/overview`, the day route and the self-report routes. Invented data throughout,
/// built around `now` in Berlin so a screenshot always reads as the present.
extension PaiFixtures {

    /// The states a screenshot run can ask for with `-PaiFixtureMe`.
    public static let meStates = ["default", "noGarmin", "empty"]

    /// The id every created entry answers under, whatever the client sent.
    public static let meCreatedEntryID = "7d1a0c22-4f6b-4a43-8a0e-5b9c1f2e3d40"

    private struct MeEntrySpec {
        let id: String
        let daysAgo: Int
        let hour: Int
        let minute: Int
        let text: String?
        let feel: String?
        let isPrivate: Bool
        let source: String
        let activity: (type: String, name: String, emoji: String, relation: String)?
        let session: String?
    }

    private static let meEntrySpecs: [MeEntrySpec] = [
        MeEntrySpec(
            id: "00000000-0000-4000-8000-000000000001", daysAgo: 0, hour: 20, minute: 41,
            text: "Long call tonight, still thinking about it. Not bad, just a lot. Glad I went climbing first.",
            feel: "okay", isPrivate: true, source: "ios", activity: nil, session: nil),
        MeEntrySpec(
            id: "00000000-0000-4000-8000-000000000002", daysAgo: 0, hour: 20, minute: 12,
            text: "Got the orange one I kept falling off. Hands are done, head is quiet.", feel: "good",
            isPrivate: false, source: "ios", activity: ("bouldering", "bouldering", "🧗", "after"), session: nil),
        MeEntrySpec(
            id: "00000000-0000-4000-8000-000000000003", daysAgo: 2, hour: 17, minute: 30,
            text: "Up on the ridge, cold and clear, nobody around. Want to remember this light. More Sundays like this.",
            feel: "good", isPrivate: false, source: "computer", activity: ("hiking", "a hike", "🥾", "during"),
            session: nil),
        MeEntrySpec(
            id: "00000000-0000-4000-8000-000000000004", daysAgo: 2, hour: 22, minute: 5,
            text: "Couldn't switch off for a while. Wrote it down so it is out of my head.", feel: nil,
            isPrivate: true, source: "watch", activity: nil, session: nil),
        MeEntrySpec(
            id: "00000000-0000-4000-8000-000000000005", daysAgo: 5, hour: 16, minute: 20,
            text: "Too many things open at once and I haven't even started the one that matters. Closing the laptop and going for a ride.",
            feel: "heavy", isPrivate: false, source: "session", activity: nil, session: "Fleet rollout session"),
        MeEntrySpec(
            id: "00000000-0000-4000-8000-000000000006", daysAgo: 5, hour: 19, minute: 5, text: nil, feel: "good",
            isPrivate: false, source: "ios", activity: ("cycling", "a ride", "🚴", "after"), session: nil),
        MeEntrySpec(
            id: "00000000-0000-4000-8000-000000000007", daysAgo: 18, hour: 21, minute: 10,
            text: "Cooked the big pot of chili for everyone. Long table, good evening.", feel: nil,
            isPrivate: false, source: "ios", activity: nil, session: nil),
    ]

    private static func meReport(_ spec: MeEntrySpec, presenter: MePresenter, now: Date) -> [String: Any] {
        let day = presenter.calendar.date(byAdding: .day, value: -spec.daysAgo, to: now) ?? now
        let moment =
            presenter.calendar.date(bySettingHour: spec.hour, minute: spec.minute, second: 0, of: day) ?? day
        let at = AlarmTime.wireString(moment)
        var row: [String: Any] = [
            "id": spec.id, "at": at, "created_at": at, "edited_at": NSNull(),
            "text": spec.text ?? NSNull(), "feel": spec.feel ?? NSNull(), "private": spec.isPrivate,
            "redacted": false, "source": spec.source,
            "session_id": spec.session == nil ? NSNull() : "305df4d3-1554-4fc3-be04-39a354a9e619",
            "session_title": spec.session ?? NSNull(),
        ]
        if let activity = spec.activity {
            row["context"] = [
                "activity": [
                    "type": activity.type, "name": activity.name, "emoji": activity.emoji,
                    "relation": activity.relation, "start_at": at, "duration_s": 5400,
                ]
            ]
        } else {
            row["context"] = ["activity": NSNull()]
        }
        return row
    }

    private static func meEntries(state: String?, now: Date) -> [[String: Any]] {
        guard state != "empty" else { return [] }
        let presenter = MePresenter()
        return meEntrySpecs.map { meReport($0, presenter: presenter, now: now) }
    }

    private static func meJSON(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }

    private static func meDays(state: String?, now: Date, end: String?) -> [[String: Any]] {
        let presenter = MePresenter()
        let todayKey = presenter.dayKey(now)
        let endKey = end ?? todayKey
        let entries = meEntries(state: state, now: now)
        let garmin = state != "noGarmin"
        // Sleep in hours, wake battery, activity emojis, PAI messages per day, oldest first.
        let sleep = [7.4, 6.9, 7.8, 8.3, 8.0, 7.2, 7.5, 7.1, 6.1, 7.7, 8.2, 8.0, 7.3, 7.6]
        let battery = [72, 58, 69, 79, 75, 63, 70, 66, 48, 76, 80, 77, 71, 74]
        let moves: [[(String, String)]] = [
            [("🏋️", "strength")], [("🧗", "bouldering")], [("🚴", "cycling")], [("🥾", "hiking")], [],
            [("🏋️", "strength")], [("🧗", "bouldering")], [], [("🚴", "cycling")], [("🧗", "bouldering")], [],
            [("🥾", "hiking")], [("🏋️", "strength")], [("🧗", "bouldering")],
        ]
        let messages = [12, 31, 9, 4, 0, 18, 11, 14, 27, 16, 5, 1, 7, 9]
        let morning: [Int?] = [35, 20, 90, nil, nil, 25, 60, nil, 85, 15, nil, nil, 40, 77]
        var days: [[String: Any]] = []
        for index in 0..<14 {
            let offset = index - 13
            guard let key = presenter.shift(key: endKey, byDays: offset), let start = presenter.date(forKey: key)
            else { continue }
            let isToday = key == todayKey
            var day: [String: Any] = ["date": key, "final": !isToday]
            func time(_ hour: Int, _ minute: Int) -> String {
                AlarmTime.wireString(
                    presenter.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start)
            }
            let hasBody = garmin && !(index == 7 && !isToday)
            day["body"] =
                hasBody
                ? [
                    "sleep_seconds": Int(sleep[index] * 3600), "sleep_score": 78, "wake_at": time(6, 48),
                    "body_battery_wake": battery[index], "readiness": 70, "hrv_status": "balanced",
                ] as [String: Any] : NSNull()
            day["activities"] =
                garmin
                ? moves[index].map {
                    [
                        "type": $0.1, "name": $0.1, "emoji": $0.0, "start_at": time(18, 10), "duration_s": 5100,
                        "distance_m": $0.1 == "cycling" ? 21000 : (NSNull() as Any),
                    ]
                } : []
            day["pai"] =
                messages[index] > 0
                ? [
                    "messages": messages[index], "sessions": max(1, messages[index] / 4),
                    "first_message_at": time(8, 5), "last_message_at": time(21, 20),
                    "overnight_agent_minutes": index % 4 == 1 ? 180 : 0,
                ] as [String: Any] : NSNull()
            day["wake_to_first_message_min"] = morning[index].map { $0 as Any } ?? NSNull()
            day["plan"] =
                isToday
                ? ["appetite": "light day", "planned": 3, "done": 2, "added": 1] as [String: Any] : NSNull()
            day["entries"] =
                entries.filter {
                    guard let at = $0["at"] as? String, let date = IsoTimestamp.date(from: at) else { return false }
                    return presenter.dayKey(date) == key
                }.map { entry in
                    ["id": entry["id"] ?? "", "at": entry["at"] ?? "", "feel": entry["feel"] ?? NSNull(),
                        "private": entry["private"] ?? false] as [String: Any]
                }
            day["held"] =
                index % 3 == 0
                ? [
                    ["project": "FleetRollout", "label": "Fleet rollout", "minutes": 180],
                    ["project": "DetectionRules", "label": "Detection rules", "minutes": 60],
                    ["project": "HikingPlans", "label": "Hiking plans", "minutes": 20],
                ] : []
            days.append(day)
        }
        return days
    }

    /// `GET /api/me/overview` for one of ``meStates``.
    public static func meOverview(state: String?, end: String?, now: Date = Date()) -> Data {
        let presenter = MePresenter()
        let entries = meEntries(state: state, now: now)
        let garmin = state != "noGarmin"
        let notes: [[String: Any]] =
            state == "empty"
            ? []
            : [
                ["key": "about_me", "title": "About me", "note_id": "6a0b5f2e-9d47-4c1a-8f30-2b7e5c918d64"],
                ["key": "compass", "title": "Compass", "note_id": "6a0b5f2e-9d47-4c1a-8f30-2b7e5c918d64"],
                ["key": "now", "title": "Now", "note_id": "6a0b5f2e-9d47-4c1a-8f30-2b7e5c918d64"],
            ]
        let overview: [String: Any] = [
            "generated_at": AlarmTime.wireString(now), "timezone": "Europe/Berlin",
            "today": presenter.dayKey(now),
            "sources": [
                "garmin": ["status": garmin ? "ok" : "not_configured", "as_of": garmin ? AlarmTime.wireString(now) as Any : NSNull()],
                "plan": ["status": "ok"],
            ],
            "days": meDays(state: state, now: now, end: end),
            "recent_entries": Array(entries.prefix(2)),
            "looking_back": NSNull(),
            "notes": notes,
            "review": state == "empty"
                ? NSNull()
                : [
                    "title": "Week 47 review", "note_id": "6a0b5f2e-9d47-4c1a-8f30-2b7e5c918d64", "week": 47,
                    "compass_session_prompt": "Talk through the compass",
                ] as [String: Any],
        ]
        return meJSON(overview)
    }

    /// `GET /api/me/day/{date}`: the overview's day with the entries in full and the phases held.
    public static func meDay(date: String, state: String?, now: Date = Date()) -> Data {
        let presenter = MePresenter()
        let all = meDays(state: state, now: now, end: nil)
        var day = all.first { ($0["date"] as? String) == date } ?? ["date": date, "final": true]
        let entries = meEntries(state: state, now: now).filter {
            guard let at = $0["at"] as? String, let moment = IsoTimestamp.date(from: at) else { return false }
            return presenter.dayKey(moment) == date
        }
        day["entries"] = entries
        if let held = day["held"] as? [[String: Any]], !held.isEmpty {
            day["held"] = held.map { entry in
                [
                    "project": entry["project"] ?? "",
                    "phases": [
                        [
                            "name": entry["label"] ?? "", "summary": "Worked through the open questions and wrote them down.",
                            "minutes": entry["minutes"] ?? 0, "summary_stale": false,
                        ]
                    ],
                ] as [String: Any]
            }
        }
        return meJSON(day)
    }

    /// `GET /api/me/self-reports`, filtered by `feel` and `private_only` the way the server does.
    public static func meSelfReports(state: String?, query: [URLQueryItem], now: Date = Date()) -> Data {
        let feel = query.first { $0.name == "feel" }?.value
        let privateOnly = query.first { $0.name == "private_only" }?.value == "1"
        let rows = meEntries(state: state, now: now).filter { row in
            if let feel, (row["feel"] as? String) != feel { return false }
            if privateOnly, (row["private"] as? Bool) != true { return false }
            return true
        }
        return meJSON(["self_reports": rows, "next_before": NSNull()])
    }

    /// The entry a create or a patch answers: what was sent, stored under ``meCreatedEntryID``.
    public static func meCreatedEntry(requestBody: Data?, now: Date = Date()) -> Data {
        let sent = (requestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let at = (sent["at"] as? String) ?? AlarmTime.wireString(now)
        let row: [String: Any] = [
            "id": (sent["id"] as? String) ?? meCreatedEntryID, "at": at, "created_at": at,
            "edited_at": NSNull(), "text": sent["text"] ?? NSNull(), "feel": sent["feel"] ?? NSNull(),
            "private": sent["private"] ?? false, "redacted": false, "source": "ios", "session_id": NSNull(),
            "session_title": NSNull(), "context": ["activity": NSNull()],
        ]
        return meJSON(row)
    }

    /// The Me routes of the fixture table; nil for any other request.
    static func meRoute(
        method: String, path: String, query: [URLQueryItem], body: Data?, state: String?, now: Date = Date()
    ) -> (status: Int, body: Data)? {
        if method == "GET", path == "/api/me/overview" {
            let end = query.first { $0.name == "end" }?.value
            return (200, meOverview(state: state, end: end, now: now))
        }
        if method == "GET", path.hasPrefix("/api/me/day/") {
            return (200, meDay(date: String(path.dropFirst("/api/me/day/".count)), state: state, now: now))
        }
        if path == "/api/me/self-reports" {
            if method == "GET" { return (200, meSelfReports(state: state, query: query, now: now)) }
            if method == "POST" { return (201, meCreatedEntry(requestBody: body, now: now)) }
        }
        if path.hasPrefix("/api/me/self-reports/") {
            if method == "PATCH" { return (200, meCreatedEntry(requestBody: body, now: now)) }
            if method == "DELETE" { return (200, meJSON(["id": "x", "deleted_at": AlarmTime.wireString(now)])) }
            if method == "POST", path.hasSuffix("/restore") { return (200, meCreatedEntry(requestBody: nil, now: now)) }
        }
        return nil
    }
}
