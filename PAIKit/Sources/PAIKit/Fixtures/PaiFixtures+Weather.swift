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
        let body: (_ location: String, _ now: String, _ later: String) -> String = { location, now, later in
            """
            {"location": \(location), "computed_at": "\(at(0))", "now": \(now), "later": \(later), \
            "attribution": "\(attribution)"}
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
