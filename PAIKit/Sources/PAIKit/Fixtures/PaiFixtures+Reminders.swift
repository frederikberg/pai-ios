import Foundation

/// The reminders corpus, with places that exist nowhere: "Office" and "Home". Five reminders cover
/// what the list draws differently: a place trigger, a Home Assistant trigger with a condition and
/// a window, a polling script that is checking, one that is failing, and one that has fired.
extension PaiFixtures {

    /// The reminder the `reminder` fixture route opens: the polling script, which has the richest
    /// detail (a last result, history and a script).
    public static let reminderFixtureId = "7e3b2c10-4d5a-4e6f-8a9b-0c1d2e3f4a5b"

    /// `GET /api/reminders`.
    public static let reminders = #"""
        {
          "reminders": [
            {
              "id": "1a2b3c4d-0000-4c1a-8f30-2b7e5c918e01", "name": "office-library-book",
              "title": "Library book", "trigger": {"kind": "place", "place": "Office", "on": "enter", "dwell_s": 0},
              "mode": "once", "state": "armed", "paused_reason": null,
              "last_check_at": null, "next_check_at": null, "last_fired_at": null, "fired_count": 0,
              "expires_at": "2027-02-23T08:00:00+00:00", "consecutive_failures": 0, "cpu_ms_today": 0,
              "has_script": false
            },
            {
              "id": "1a2b3c4d-0000-4c1a-8f30-2b7e5c918e02", "name": "door-bins",
              "title": "Bins", "trigger": {"kind": "ha", "entity_id": "binary_sensor.front_door", "from": "off", "to": "on"},
              "mode": "once", "state": "armed", "paused_reason": null,
              "last_check_at": null, "next_check_at": null, "last_fired_at": null, "fired_count": 0,
              "expires_at": "2027-02-23T08:00:00+00:00", "consecutive_failures": 0, "cpu_ms_today": 0,
              "has_script": false
            },
            {
              "id": "7e3b2c10-4d5a-4e6f-8a9b-0c1d2e3f4a5b", "name": "page-date",
              "title": "Date published", "trigger": {"kind": "poll", "interval_s": 3600},
              "mode": "once", "state": "armed", "paused_reason": null,
              "last_check_at": "2026-11-25T13:05:00+00:00", "next_check_at": "2026-11-25T14:05:00+00:00",
              "last_fired_at": null, "fired_count": 0,
              "expires_at": "2027-02-23T08:00:00+00:00", "consecutive_failures": 0, "cpu_ms_today": 410,
              "has_script": true
            },
            {
              "id": "1a2b3c4d-0000-4c1a-8f30-2b7e5c918e04", "name": "status-page",
              "title": "Status page changed", "trigger": {"kind": "poll", "interval_s": 900},
              "mode": "repeat", "state": "failing", "paused_reason": null,
              "last_check_at": "2026-11-25T13:45:00+00:00", "next_check_at": "2026-11-25T14:00:00+00:00",
              "last_fired_at": "2026-11-20T09:12:00+00:00", "fired_count": 2,
              "expires_at": null, "consecutive_failures": 3, "cpu_ms_today": 980,
              "has_script": true
            },
            {
              "id": "1a2b3c4d-0000-4c1a-8f30-2b7e5c918e05", "name": "parcel-pickup",
              "title": "Parcel pickup", "trigger": {"kind": "place", "place": "Home", "on": "exit", "dwell_s": 300},
              "mode": "once", "state": "fired", "paused_reason": null,
              "last_check_at": null, "next_check_at": null, "last_fired_at": "2026-11-18T08:41:00+00:00",
              "fired_count": 1, "expires_at": null, "consecutive_failures": 0, "cpu_ms_today": 0,
              "has_script": false
            }
          ]
        }
        """#

    /// `GET /api/reminders/{id}` for ``reminderFixtureId``.
    public static let reminderDetail = #"""
        {
          "id": "7e3b2c10-4d5a-4e6f-8a9b-0c1d2e3f4a5b", "name": "page-date",
          "title": "Date published", "trigger": {"kind": "poll", "interval_s": 3600},
          "mode": "once", "state": "armed", "paused_reason": null,
          "last_check_at": "2026-11-25T13:05:00+00:00", "next_check_at": "2026-11-25T14:05:00+00:00",
          "last_fired_at": null, "fired_count": 0,
          "expires_at": "2027-02-23T08:00:00+00:00", "consecutive_failures": 0, "cpu_ms_today": 410,
          "has_script": true,
          "body": "The announcements page now lists a date.",
          "condition_place": null,
          "script_source": "const res = await fetch(\"https://example.org/announcements\");\nconst html = await res.text();\nconst date = html.match(/\\b\\d{1,2}\\.\\d{1,2}\\.20\\d\\d\\b/)?.[0];\nconsole.log(JSON.stringify(date ? { fire: true, body: date } : { fire: false }));\n",
          "script_runtime": "bun", "script_timeout_s": 20, "script_net": "locked",
          "cooldown_s": null,
          "active_window": {"days": [1, 2, 3, 4, 5], "from": "07:00", "to": "22:00"},
          "timezone": "Europe/Berlin", "not_before": null, "memo": {},
          "last_result": {
            "ok": true, "exit_code": 0, "fire": false, "error": null, "cpu_ms": 96, "duration_ms": 412,
            "stdout_tail": "{\"fire\":false}", "stderr_tail": ""
          },
          "task_id": null, "origin_session_id": null,
          "events": [
            {"id": 3, "at": "2026-11-25T08:00:00+00:00", "kind": "recovered", "detail": {}},
            {"id": 2, "at": "2026-11-25T07:00:00+00:00", "kind": "failed", "detail": {"message": "HTTP 503"}},
            {"id": 1, "at": "2026-11-24T16:20:00+00:00", "kind": "created", "detail": {"trigger": "poll"}}
          ]
        }
        """#

    /// `POST /api/reminders/{id}/test`.
    public static let reminderTested = #"""
        {
          "ok": true, "fire": false, "title": "Date published", "body": "The announcements page now lists a date.",
          "would_notify": false, "reason_not": null, "error": null, "exit_code": 0,
          "stdout_tail": "{\"fire\":false}", "stderr_tail": "", "cpu_ms": 96, "duration_ms": 412, "notified": false
        }
        """#

    /// `GET /api/location/day` for a Berlin day: four stays between invented places, answered for
    /// whichever date is asked, so the Me day detail shows its Where line on any day it opens.
    public static func locationDay(date: String) -> String {
        let before = shifted(day: date, by: -1)
        let after = shifted(day: date, by: 1)
        return """
            {
              "date": "\(date)", "coverage": "full",
              "stays": [
                {"place": "Home", "locality": null, "from": "\(before)T21:00:00+00:00", "to": "\(date)T07:10:00+00:00"},
                {"place": "Office", "locality": null, "from": "\(date)T07:40:00+00:00", "to": "\(date)T16:20:00+00:00"},
                {"place": null, "locality": "Springfield", "from": "\(date)T17:00:00+00:00", "to": "\(date)T18:30:00+00:00"},
                {"place": "Home", "locality": null, "from": "\(date)T18:50:00+00:00", "to": "\(after)T06:00:00+00:00"}
              ],
              "moved_km": 14.2, "first_at": "\(date)T07:10:00+00:00", "last_at": "\(date)T21:50:00+00:00"
            }
            """
    }

    /// The `yyyy-MM-dd` key `days` away from `day`, by the proleptic Gregorian calendar in UTC.
    private static func shifted(day: String, by days: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
            let moved = calendar.date(byAdding: .day, value: days, to: start)
        else { return day }
        let c = calendar.dateComponents([.year, .month, .day], from: moved)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `POST /api/location/points`.
    public static let locationPointsAnswer = #"""
        {"stored": 1, "merged": 0, "rejected": 0, "history": true, "places_version": "v-fixture-1"}
        """#

    /// `GET /api/places/monitor`: two invented places in the mid-Atlantic.
    public static let placesMonitor = #"""
        {
          "places": [
            {"id": "9b8a7c6d-0000-4c1a-8f30-2b7e5c918f01", "lat": 10.0, "lon": -30.0, "radius_m": 300},
            {"id": "9b8a7c6d-0000-4c1a-8f30-2b7e5c918f02", "lat": 10.02, "lon": -30.02, "radius_m": 200}
          ],
          "places_version": "v-fixture-1"
        }
        """#
}
