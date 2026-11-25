import XCTest

@testable import PAIKit

@MainActor
final class SessionListFilterPersistenceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "pai-test-filters-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore() -> SessionListStore {
        SessionListStore(api: FakeSessionListApi(), storage: defaults)
    }

    func testScopeAndHideClosedComeBackInANewStore() async {
        let first = makeStore()
        first.setScope(.both)
        first.setHideClosed(true)

        let second = makeStore()
        XCTAssertEqual(second.scope, .both)
        XCTAssertTrue(second.hideClosed)
    }

    func testAFreshStoreStartsOnTheDefaults() async {
        let store = makeStore()
        XCTAssertEqual(store.scope, .manual)
        XCTAssertFalse(store.hideClosed)
        XCTAssertNil(store.machineFilter)
    }

    func testAKnownMachineIsRestoredOnceTheListIsKnown() async {
        makeStore().setMachineFilter("laptop")

        let store = makeStore()
        XCTAssertNil(store.machineFilter, "nothing to check the slug against yet")
        store.restoreMachineFilter(knownSlugs: [])
        XCTAssertNil(store.machineFilter, "an empty list is not an answer")
        store.restoreMachineFilter(knownSlugs: ["laptop", "vm"])
        XCTAssertEqual(store.machineFilter, "laptop")
    }

    func testAnUnknownMachineFallsBackToAllMachinesAndIsForgotten() async {
        makeStore().setMachineFilter("gone")

        let store = makeStore()
        store.restoreMachineFilter(knownSlugs: ["laptop", "vm"])
        XCTAssertNil(store.machineFilter)

        let later = makeStore()
        later.restoreMachineFilter(knownSlugs: ["gone"])
        XCTAssertNil(later.machineFilter, "the stale choice was dropped, not kept for later")
    }

    func testClearingTheMachineIsRemembered() async {
        let first = makeStore()
        first.setMachineFilter("laptop")
        first.setMachineFilter(nil)

        let second = makeStore()
        second.restoreMachineFilter(knownSlugs: ["laptop"])
        XCTAssertNil(second.machineFilter)
    }

    func testAChoiceMadeBeforeTheListLoadsIsNotOverwritten() async {
        makeStore().setMachineFilter("laptop")

        let store = makeStore()
        store.setMachineFilter("vm")
        store.restoreMachineFilter(knownSlugs: ["laptop", "vm"])
        XCTAssertEqual(store.machineFilter, "vm")
    }

    func testAStoreWithoutStorageKeepsNothing() async {
        let store = SessionListStore(api: FakeSessionListApi())
        store.setScope(.scheduled)
        XCTAssertEqual(SessionListStore(api: FakeSessionListApi(), storage: defaults).scope, .manual)
    }
}
