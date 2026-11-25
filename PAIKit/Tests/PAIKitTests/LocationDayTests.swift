import XCTest

@testable import PAIKit

private actor FakeLocationDayApi: LocationDayApiClient {
    private(set) var asked: [String] = []
    var answer: LocationDay?
    func set(answer: LocationDay?) { self.answer = answer }

    func getLocationDay(date: String) async throws -> LocationDay {
        asked.append(date)
        guard let answer else { throw PaiError.detail("not found", statusCode: 404) }
        return answer
    }
}

/// The Where line of a Me day: what it says for a full day, a day that began and ended elsewhere,
/// and a day the history knows nothing about.
final class LocationDayTests: XCTestCase {

    private let presenter = MePresenter(timeZoneName: "Europe/Berlin")

    private func day(date: String = "2026-11-24") throws -> LocationDay {
        try JSONDecoder().decode(LocationDay.self, from: Data(PaiFixtures.locationDay(date: date).utf8))
    }

    func testAFullDayReadsAsItsStaysInOrderAndTheDistance() throws {
        let line = try XCTUnwrap(presenter.locationLine(try day()))
        // The fixture's stays are in UTC; November Berlin is one hour ahead.
        XCTAssertEqual(
            line.text, "Home –08:10 · Office 08:40–17:20 · Springfield 18:00–19:30 · Home 19:50– · 14.2 km")
        XCTAssertFalse(line.hasGaps)
        XCTAssertNotNil(try day().firstAt, "the contract's first_at and last_at decode")
        XCTAssertNotNil(try day().lastAt)
    }

    func testAPartialDayIsFlaggedForGaps() throws {
        let partial = LocationDay(
            date: "2026-11-24", coverage: .partial,
            stays: [
                LocationStay(
                    place: "Home", locality: nil, from: "2026-11-24T08:00:00+00:00", to: "2026-11-24T09:00:00+00:00")
            ],
            movedKm: nil)
        let line = try XCTUnwrap(presenter.locationLine(partial))
        XCTAssertEqual(line.text, "Home 09:00–10:00")
        XCTAssertTrue(line.hasGaps)
    }

    func testADayWithNoHistoryHasNoLine() {
        let none = LocationDay(date: "2026-11-24", coverage: .none, stays: [], movedKm: 0)
        XCTAssertNil(presenter.locationLine(none))
        let empty = LocationDay(date: "2026-11-24", coverage: .full, stays: [], movedKm: 0.04)
        XCTAssertNil(presenter.locationLine(empty), "a full day with no stay and no distance says nothing")
    }

    func testAStayWithoutAPlaceOrLocalityIsNamedSomewhere() throws {
        let unnamed = LocationDay(
            date: "2026-11-24", coverage: .full,
            stays: [
                LocationStay(
                    place: nil, locality: nil, from: "2026-11-24T10:00:00+00:00", to: "2026-11-24T11:00:00+00:00")
            ],
            movedKm: nil)
        XCTAssertEqual(presenter.locationLine(unnamed)?.text, "Somewhere 11:00–12:00")
    }

    func testAnUnknownCoverageDecodesAndShowsItsStays() throws {
        let json = """
            {"date": "2026-11-24", "coverage": "sparse", "stays": [], "moved_km": 3.0}
            """
        let decoded = try JSONDecoder().decode(LocationDay.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.coverage, .unrecognized("sparse"))
        XCTAssertEqual(presenter.locationLine(decoded)?.text, "3.0 km")
    }

    @MainActor
    func testOnlyTheOwnerAsksForADay() async throws {
        let api = FakeLocationDayApi()
        await api.set(answer: try day())
        let guest = LocationDayStore(api: api, capabilities: { Capabilities(role: .guest) })
        await guest.load(date: "2026-11-24")
        XCTAssertNil(guest.day)
        let asked = await api.asked
        XCTAssertTrue(asked.isEmpty)

        let owner = LocationDayStore(api: api, capabilities: { Capabilities(role: .owner) })
        await owner.load(date: "2026-11-24")
        XCTAssertEqual(owner.day?.date, "2026-11-24")
    }

    @MainActor
    func testADayTheServerCannotAnswerShowsNothing() async {
        let api = FakeLocationDayApi()
        let store = LocationDayStore(api: api, capabilities: { Capabilities(role: .owner) })
        await store.load(date: "2026-11-24")
        XCTAssertNil(store.day)
    }
}
