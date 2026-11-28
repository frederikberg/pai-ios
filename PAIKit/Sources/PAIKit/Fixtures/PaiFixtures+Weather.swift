import Foundation

/// `GET /api/weather` and the location routes. The answer is built around `now` so the times and
/// the location's age read right whenever a screenshot is taken.
extension PaiFixtures {

    /// The states a screenshot run can ask for with `-PaiFixtureWeather`.
    public static let weatherStates = [
        "showersApproaching", "rainingNow", "dry", "noLocation", "sourceUnavailable", "forecastOnly",
    ]

    /// `GET /api/weather` for one of ``weatherStates``; any other name is the first.
    public static func weather(state: String?, now: Date = Date()) -> String {
        func at(_ minutes: Int) -> String { AlarmTime.wireString(now.addingTimeInterval(Double(minutes) * 60)) }
        let location = """
            {"lat": 50.776, "lon": 6.084, "place": "Aachen", "recorded_at": "\(at(-12))", \
            "accuracy_m": 65, "source": "ios"}
            """
        let attribution = "Radar: DWD · Forecast: Open-Meteo"
        // Twelve hours: dry, a light start near the third hour, heaviest in the sixth.
        let amounts = [0.0, 0.0, 0.3, 0.4, 0.8, 1.6, 0.5, 0.2, 0.0, 0.0, 0.0, 0.0]
        let chances = [5, 10, 40, 40, 35, 40, 30, 20, 10, 5, 5, 5]
        let strip = zip(amounts, chances).enumerated().map { hour, pair in
            let intensity = pair.0 >= 1 ? "moderate" : pair.0 >= 0.1 ? "light" : "none"
            return """
                {"start": "\(at(hour * 60))", "chance": \(pair.1), "precipitation_mm": \(pair.0), \
                "intensity": "\(intensity)"}
                """
        }.joined(separator: ", ")
        // The forecast beside the rain answer: a filled one wherever a location is known and the
        // sources answer, an empty one naming why otherwise.
        let symbols = [
            "partly", "partly", "cloudy", "rain", "rain", "rain", "cloudy", "cloudy", "clear", "clear", "clear",
            "fog",
        ]
        let temps = [9, 11, 12, 11, 10, 8, 7, 5, 3, 1, 0, -1]
        let indexes = [1.2, 2.6, 3.4, 2.1, 1.0, 0.4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let hours = symbols.indices.map { hour in
            """
            {"start": "\(at(hour * 60))", "temp": \(temps[hour]), "symbol": "\(symbols[hour])", \
            "night": \(hour >= 8), "uv": \(indexes[hour])}
            """
        }.joined(separator: ", ")
        let day: (_ offset: Int, _ rest: String) -> String = { offset, rest in
            let date = AlarmTime.wireString(now.addingTimeInterval(Double(offset) * 86400)).prefix(10)
            return "{\"date\": \"\(date)\", \(rest)}"
        }
        let days = [
            day(0, #""symbol": "rain", "temp_max": 12, "temp_min": -1, "chance": 80"#),
            day(1, #""symbol": "thunder", "temp_max": 9, "temp_min": 2, "chance": 65"#),
            day(2, #""symbol": "snow", "temp_max": 1, "temp_min": -6, "chance": 40"#),
            day(3, #""symbol": "clear", "temp_max": 4, "temp_min": -4, "chance": null"#),
        ].joined(separator: ", ")
        let forecast = """
            {"reason": null, "symbol": "rain", "night": false, "temp_now": 9, "temp_min": -1, "temp_max": 12, \
            "hours": [\(hours)], "uv": {"now": 1.2, "peak": 3.4, "peak_at": "\(at(120))"}, "days": [\(days)]}
            """
        let noForecast: (_ reason: String) -> String = { reason in
            """
            {"reason": "\(reason)", "symbol": null, "night": false, "temp_now": null, "temp_min": null, \
            "temp_max": null, "hours": [], "uv": null, "days": []}
            """
        }
        let conditions: String
        switch state {
        case "noLocation": conditions = noForecast("no_location")
        case "sourceUnavailable": conditions = noForecast("source_unavailable")
        default: conditions = forecast
        }
        let body: (_ location: String, _ now: String, _ later: String) -> String = { location, now, later in
            """
            {"location": \(location), "computed_at": "\(at(0))", "now": \(now), "later": \(later), \
            "attribution": "\(attribution)", "conditions": \(conditions)}
            """
        }
        switch state {
        case "rainingNow":
            return body(
                location,
                """
                {"chance": 100, "verdict": "rain", "raining_now": true, "starts_at": null, \
                "ends_at": "\(at(25))", "nearest_km": 0.0, "direction": null, "trend": "passing", \
                "method": "radar", "reason": null}
                """,
                """
                {"chance": 55, "verdict": "maybe", "at": "\(at(180))", "method": "radar+forecast", "reason": null}
                """)
        case "dry":
            return body(
                location,
                """
                {"chance": 3, "verdict": "dry", "raining_now": false, "starts_at": null, "ends_at": null, \
                "nearest_km": 41.0, "direction": "NW", "trend": "leaving", "method": "radar", "reason": null}
                """,
                """
                {"chance": 4, "verdict": "dry", "at": null, "method": "radar+forecast", "reason": null}
                """)
        case "noLocation":
            return body(
                "null",
                """
                {"chance": null, "verdict": "unknown", "raining_now": false, "starts_at": null, \
                "ends_at": null, "nearest_km": null, "direction": null, "trend": null, "method": "forecast", \
                "reason": "no_location"}
                """,
                """
                {"chance": null, "verdict": "unknown", "at": null, "method": "forecast", "reason": "no_location"}
                """)
        case "sourceUnavailable":
            return body(
                location,
                """
                {"chance": null, "verdict": "unknown", "raining_now": false, "starts_at": null, \
                "ends_at": null, "nearest_km": null, "direction": null, "trend": null, "method": "forecast", \
                "reason": "source_unavailable"}
                """,
                """
                {"chance": null, "verdict": "unknown", "at": null, "method": "forecast", \
                "reason": "source_unavailable"}
                """)
        case "forecastOnly":
            return body(
                location.replacingOccurrences(of: "Aachen", with: "Lisbon"),
                """
                {"chance": 20, "verdict": "unlikely", "raining_now": false, "starts_at": null, \
                "ends_at": null, "nearest_km": null, "direction": null, "trend": null, "method": "forecast", \
                "reason": null}
                """,
                """
                {"chance": 62, "verdict": "rain", "at": "\(at(900))", "method": "forecast", "reason": null}
                """)
        default:
            return body(
                location,
                """
                {"chance": 70, "verdict": "rain", "raining_now": false, "starts_at": "\(at(20))", \
                "ends_at": null, "nearest_km": 8.4, "direction": "W", "trend": "approaching", \
                "method": "radar", "reason": null}
                """,
                """
                {"chance": 40, "verdict": "maybe", "at": "\(at(170))", "method": "radar+forecast", "reason": null, \
                "hours": [\(strip)], "heaviest_at": "\(at(300))", "total_mm": 3.8}
                """)
        }
    }

    /// `GET /api/sign-ins`: this phone's own, active sign-in and another phone's.
    public static let mySignIns: String = #"""
        [
          {"id": "5c1f0a52-7a5e-4b43-9d58-1b1f6d3a0c01", "kind": "app", "name": "Test iPhone",
           "active": true, "current": true},
          {"id": "5c1f0a52-7a5e-4b43-9d58-1b1f6d3a0c02", "kind": "app", "name": "iPad",
           "active": true, "current": false}
        ]
        """#
}
