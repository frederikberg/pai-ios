import XCTest

@testable import PAIKit

/// What an opened search starts with, and that it takes nothing of the person's own choices away.
@MainActor
final class SessionSearchDefaultsTests: XCTestCase {
    func testAnOpenedSearchReadsMeaningOverTheLastThirtyDaysAndLeavesThePlainListAlone() async {
        let store = SessionListStore(api: FakeSessionListApi())
        XCTAssertNil(store.timeWindow, "the plain list is not narrowed")
        XCTAssertTrue(store.semanticMode)

        store.setSearching(true)
        XCTAssertEqual(store.timeWindow, .preset(.last30Days))
        store.setSearching(false)
        XCTAssertNil(store.timeWindow, "the window came with the search and leaves with it")
    }

    func testAWindowThePersonPickedOrClearedIsTheirs() async {
        let store = SessionListStore(api: FakeSessionListApi())
        store.setTimeWindow(.preset(.today))
        store.setSearching(true)
        XCTAssertEqual(store.timeWindow, .preset(.today), "a set window is not replaced")
        store.setSearching(false)
        XCTAssertEqual(store.timeWindow, .preset(.today))

        store.setTimeWindow(nil)
        store.setSearching(true)
        store.setTimeWindow(.preset(.last7Days))
        store.setSearching(false)
        XCTAssertEqual(store.timeWindow, .preset(.last7Days), "one picked during the search stays after it")

        store.setTimeWindow(nil)
        store.setSearching(true)
        store.setTimeWindow(nil)
        XCTAssertNil(store.timeWindow, "cleared during a search, all time is searched")
    }
}
