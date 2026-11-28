import XCTest

@testable import PAIKit

/// The person's order of apps: what it makes of the apps a client has, what a rearrangement on
/// one client leaves of another client's entries, and where switching between apps lands.
final class AppOrderTests: XCTestCase {
    private func entries(_ ids: [String]) -> [AppEntry] {
        ids.map { AppEntry(id: $0, title: $0, systemImage: "app", route: .canteen) }
    }

    func testTheLineSplitsShownDirectlyFromMoreAndUnnamedAppsComeLast() {
        let arranged = AppOrder.arrange(
            ["todos", "ghost", "sessions", AppOrder.line, "weather", "todos"],
            entries(["sessions", "notes", "todos", "weather", "alarm"]))
        XCTAssertEqual(arranged.pinned.map(\.id), ["todos", "sessions"], "an id this client has no app for is skipped")
        XCTAssertEqual(arranged.more.map(\.id), ["weather", "notes", "alarm"], "named ones first, a repeat is ignored")
    }

    func testAnOrderNobodySetPutsEveryAppUnderMoreInTheRegistryOrder() {
        let arranged = AppOrder.arrange([], entries(["sessions", "notes"]))
        XCTAssertTrue(arranged.pinned.isEmpty)
        XCTAssertEqual(arranged.more.map(\.id), ["sessions", "notes"])
    }

    func testARearrangementKeepsAnotherClientsAppsOnTheirSideOfTheLine() {
        let stored = ["sessions", "memory", "todos", AppOrder.line, "magic", "weather"]
        let next = AppOrder.reordered(stored: stored, sequence: ["todos", AppOrder.line, "weather", "sessions"])
        XCTAssertEqual(next, ["todos", "memory", AppOrder.line, "weather", "sessions", "magic"])
        // What this client then draws is exactly what the person arranged.
        let arranged = AppOrder.arrange(next, entries(["sessions", "todos", "weather"]))
        XCTAssertEqual(arranged.pinned.map(\.id), ["todos"])
        XCTAssertEqual(arranged.more.map(\.id), ["weather", "sessions"])
    }

    func testSleepModeKeepsThePersonsOrderWithoutTheAppsItPutsAway() {
        let order = ["weather", "sessions", "reports", "todos", AppOrder.line, "notes"]
        let owner = Capabilities(role: .owner)
        let awake = AppRegistry.arranged(for: owner, order: order, asleep: false)
        let night = AppRegistry.arranged(for: owner, order: order, asleep: true)
        XCTAssertEqual(awake.pinned.map(\.id), ["weather", "sessions", "reports", "todos"])
        XCTAssertEqual(night.pinned.map(\.id), ["weather", "todos"])
        XCTAssertEqual(night.more.first?.id, "notes")
        XCTAssertFalse(night.all.contains { $0.isNightBlocked })
    }

    // MARK: Switching

    private func app(_ id: String) throws -> AppEntry {
        try XCTUnwrap(AppRegistry.all.first { $0.id == id })
    }

    func testAnAppOpensWhereItWasLeftAndTheSessionsReturnToTheOpenSession() throws {
        let places = AppPlaces()
        let inSession: [Route] = [.session(id: "s1"), .terminal(sessionID: "s1")]

        let notes = places.path(switchingTo: try app("notes"), from: inSession, asleep: false)
        XCTAssertEqual(notes, [.apps, .notes], "an app sits on the start screen, so Back leads there")

        let inNote = notes + [.note(id: "n1")]
        let todos = places.path(
            switchingTo: try app("todos"), start: .todosPage(.view("today")), from: inNote, asleep: false)
        XCTAssertEqual(todos, [.apps, .todosPage(.view("today"))])

        XCTAssertEqual(
            places.path(switchingTo: try app("notes"), from: todos, asleep: false), [.apps, .notes, .note(id: "n1")])
        XCTAssertEqual(
            places.path(switchingTo: try app("sessions"), from: [.apps, .notes, .note(id: "n1")], asleep: false),
            inSession)
    }

    func testPickingTheAppOneIsInChangesNothing() throws {
        let path: [Route] = [.apps, .notes, .note(id: "n1")]
        XCTAssertEqual(AppPlaces().path(switchingTo: try app("notes"), from: path, asleep: false), path)
    }

    func testWhileAsleepNothingIsPutBackThatSleepModePutsAway() throws {
        let places = AppPlaces()
        // A report was opened from a todo, and a session from the report.
        let left: [Route] = [.apps, .todos, .report(id: "r1"), .session(id: "s1")]
        _ = places.path(switchingTo: try app("weather"), from: left, asleep: false)
        let back = places.path(switchingTo: try app("todos"), from: [.weather], asleep: true)
        XCTAssertEqual(back, [.todos], "the sleep screen is the root, and the agents' screens stay away")
        XCTAssertFalse(back.contains(where: \.isSessionSurface))
    }

    func testTheAppOfAPathIsTheAppOfItsFirstScreen() {
        XCTAssertEqual(AppRegistry.appID(of: []), AppRegistry.sessionsID)
        XCTAssertNil(AppRegistry.appID(of: [.apps]))
        XCTAssertEqual(AppRegistry.appID(of: [.apps, .todos, .session(id: "s")]), "todos")
        XCTAssertEqual(AppRegistry.appID(of: [.session(id: "s"), .report(id: "r")]), AppRegistry.sessionsID)
        // Every app's own first screen is recognised as that app, or the Apps list could never
        // say where the person is.
        for entry in AppRegistry.all {
            XCTAssertEqual(AppRegistry.appID(of: entry.route.map { [$0] } ?? []), entry.id, entry.id)
        }
    }
}

/// Writing the order from the phone.
@MainActor
final class AppOrderSettingTests: XCTestCase {
    func testArrangingOnThePhoneWritesTheWholeOrderWithOtherClientsAppsKept() async throws {
        let base = try JSONDecoder().decode(SettingsResponse.self, from: Data(PaiFixtures.settingsRegistryOwner.utf8))
        var person = base.person
        person["app_order"] = .array(["sessions", "memory", AppOrder.line, "todos"].map(SettingValue.string))
        let api = FakeSettingsRegistryApi(
            response: SettingsResponse(schema: base.schema, person: person, instance: base.instance))
        let store = SettingsRegistryStore(api: api, cache: SettingsInMemoryKeyValueStore())
        await store.load()
        XCTAssertEqual(store.appOrder, ["sessions", "memory", AppOrder.line, "todos"])

        let taken = await store.setAppOrder(sequence: ["todos", "sessions", AppOrder.line, "notes"])
        XCTAssertTrue(taken)
        let patches = await api.personPatches
        XCTAssertEqual(
            patches.last?["app_order"]?.stringList, ["todos", "sessions", "memory", AppOrder.line, "notes"])
        XCTAssertEqual(store.appOrder, ["todos", "sessions", "memory", AppOrder.line, "notes"])
    }
}
