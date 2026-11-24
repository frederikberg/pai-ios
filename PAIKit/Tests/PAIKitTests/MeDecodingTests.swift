import XCTest

@testable import PAIKit

/// Apple's `JSONDecoder` refuses a fractional number for an `Int`, Linux's accepts one, so these
/// feed the odd shapes explicitly: a green Linux run only shows the lenient code path rounds and
/// tolerates them, not that Apple's decoder reaches it.
final class MeDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testFractionalNumbersInIntegerFieldsRoundInsteadOfFailingTheDay() throws {
        let day = try decode(
            MeDay.self,
            #"""
            {"date": "2026-11-24", "wake_to_first_message_min": 41.5,
             "body": {"sleep_seconds": 27000.4, "sleep_score": 81.5, "body_battery_wake": 28.5, "readiness": 63.0},
             "activities": [{"duration_s": 3600.5, "distance_m": 10250.25}],
             "pai": {"messages": 12.0, "sessions": 3.5, "overnight_agent_minutes": 7.5},
             "plan": {"planned": 6.0, "done": 4.5, "added": 1.5},
             "held": [{"project": "p", "minutes": 90.5, "phases": [{"name": "n", "minutes": 12.5}]}],
             "entries": [{"id": "e", "at": "2026-11-24T08:00:00+00:00",
                          "context": {"activity": {"relation": "after", "duration_s": 1800.5}}}]}
            """#)
        XCTAssertEqual(day.wakeToFirstMessageMin, 42)
        XCTAssertEqual(day.body?.sleepSeconds, 27000)
        XCTAssertEqual(day.body?.sleepScore, 82)
        XCTAssertEqual(day.body?.bodyBatteryWake, 29)
        XCTAssertEqual(day.body?.readiness, 63)
        XCTAssertEqual(day.activities.first?.durationS, 3601)
        XCTAssertEqual(day.activities.first?.distanceM, 10250.25)
        XCTAssertEqual(day.pai?.messages, 12)
        XCTAssertEqual(day.pai?.sessions, 4)
        XCTAssertEqual(day.pai?.overnightAgentMinutes, 8)
        XCTAssertEqual(day.plan?.planned, 6)
        XCTAssertEqual(day.plan?.done, 5)
        XCTAssertEqual(day.plan?.added, 2)
        XCTAssertEqual(day.held.first?.minutes, 91)
        XCTAssertEqual(day.held.first?.phases.first?.minutes, 13)
        XCTAssertEqual(day.entries.first?.context?.activity?.durationS, 1801)
    }

    func testWholeNumbersAndNegativeFractionsAreRoundedAwayFromZero() throws {
        let body = try decode(MeBody.self, #"{"sleep_seconds": 27000, "sleep_score": -28.5, "readiness": 1e3}"#)
        XCTAssertEqual(body.sleepSeconds, 27000)
        XCTAssertEqual(body.sleepScore, -29)
        XCTAssertEqual(body.readiness, 1000)
    }

    func testAnIntegerFieldHoldingGarbageIsNilAndTheRestOfTheObjectSurvives() throws {
        let body = try decode(
            MeBody.self,
            #"{"sleep_seconds": "long", "sleep_score": 1e300, "body_battery_wake": null, "readiness": 70, "hrv_status": 5}"#
        )
        XCTAssertNil(body.sleepSeconds)
        XCTAssertNil(body.sleepScore)
        XCTAssertNil(body.bodyBatteryWake)
        XCTAssertEqual(body.readiness, 70)
        XCTAssertNil(body.hrvStatus)
        let pai = try decode(MePai.self, #"{"messages": null}"#)
        XCTAssertEqual(pai.messages, 0)
    }

    func testAProjectOrPhaseWithoutANameStillDecodesAndShowsAPlaceholder() throws {
        let day = try decode(
            MeDay.self,
            #"""
            {"date": "2026-11-24", "held": [
              {"project": null, "label": null, "minutes": 30},
              {"project": null, "label": "Weekly", "minutes": 5},
              {"project": "Home", "phases": [{"name": null, "summary": "s", "minutes": 4}, {"minutes": 2}]}]}
            """#)
        XCTAssertEqual(day.held.map(\.title), [MeHeld.untitled, "Weekly", "Home"])
        XCTAssertEqual(day.held[2].phases.map(\.title), [MeHeld.untitled, MeHeld.untitled])
        XCTAssertEqual(day.held[2].phases.first?.summary, "s")
        XCTAssertEqual(Set(day.held.map(\.id)).count, 3)
    }

    func testOneMalformedStringFieldDoesNotFailTheOverview() throws {
        let overview = try decode(
            MeOverview.self,
            #"""
            {"today": "2026-11-24", "days": [{"date": "2026-11-24",
              "activities": [{"name": null, "type": 3, "start_at": 5}],
              "events": [{"title": null, "start_at": "2026-11-24T08:00:00+00:00"}],
              "plan": {"appetite": null, "planned": 2}}]}
            """#)
        let day = try XCTUnwrap(overview.days.first)
        XCTAssertEqual(day.activities.count, 1)
        XCTAssertNil(day.activities[0].type)
        XCTAssertEqual(day.events.map(\.title), [""])
        XCTAssertEqual(day.plan?.planned, 2)
    }
}
