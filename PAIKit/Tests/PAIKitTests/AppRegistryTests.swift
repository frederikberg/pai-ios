import XCTest

@testable import PAIKit

/// What the sleep screen is drawn from, which routes it puts away, and that the gate holds on every
/// way into the app.
final class AppRegistryTests: XCTestCase {
    private func owner() -> Capabilities { Capabilities(role: .owner) }
    private func guest() -> Capabilities { Capabilities(role: .guest) }

    private func sleepStore(asleep: Bool) -> SleepModeStore {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SleepModeStore(
            storage: SettingsInMemoryKeyValueStore(), now: { clock }, zone: { TimeZone(identifier: "UTC")! })
        // A window around the fixed clock, or one far from it.
        let hour = Int(clock.timeIntervalSince1970 / 3600) % 24
        let start = asleep ? (hour * 60 - 30 + 1440) % 1440 : (hour * 60 + 12 * 60) % 1440
        store.enable(window: SleepWindow(startMinute: start, endMinute: (start + 120) % 1440)!, pin: "1234")
        XCTAssertEqual(store.isAsleep, asleep)
        return store
    }

    // MARK: Which routes

    func testEveryRouteIsDecidedAndTheAgentsSurfacesAreTheOnesPutAway() {
        let putAway: [Route] = [
            .session(id: "a"), .terminal(sessionID: "a"), .createSession, .subagents(parentID: "a"), .notifications,
            .recordings, .arcSpec(specUuid: "a"), .arcSpecList, .arcReport(specUuid: "a", reportUuid: "b"),
            .arcOverview(specUuid: "a"), .schedulerList, .schedulerTask(id: nil), .computerCall, .usage, .decisions,
            .browserList, .browser(name: "a"),
        ]
        let kept: [Route] = [
            .settings, .notes, .note(id: "a"), .noteContainers, .notePreview(id: "a"), .apps, .quickActions, .canteen,
            .alarm, .weather, .cameraImport, .me,
        ]
        for route in putAway { XCTAssertTrue(route.isSessionSurface, "\(route)") }
        for route in kept { XCTAssertFalse(route.isSessionSurface, "\(route)") }
    }

    // MARK: The registry

    func testTheSleepScreenIsTheAppsListWithoutTheAppsPutAway() {
        let listed = AppRegistry.listed(for: owner()).map(\.id)
        let night = AppRegistry.listedAtNight(for: owner()).map(\.id)
        XCTAssertEqual(
            night, ["quick-actions", "me", "notes", "alarm", "weather", "canteen", "camera-import"])
        XCTAssertEqual(Set(listed).subtracting(night), ["arc", "scheduler", "usage", "decisions", "browser"])
        XCTAssertTrue(night.contains("quick-actions"))
        XCTAssertTrue(night.contains("camera-import"))
    }

    func testAnAppIsPutAwayExactlyWhenItsRouteIsAnAgentsSurface() {
        for entry in AppRegistry.all {
            XCTAssertEqual(entry.isNightBlocked, entry.route.isSessionSurface, entry.id)
        }
    }

    func testAnAppAddedToTheRegistryAppearsOnTheSleepScreenWithNoOtherEdit() {
        let added = AppEntry(id: "fixture", title: "Fixture", systemImage: "star", route: .canteen)
        let entries = AppRegistry.all + [added]
        XCTAssertEqual(AppRegistry.listed(for: owner(), in: entries).last?.id, "fixture")
        XCTAssertEqual(AppRegistry.listedAtNight(for: owner(), in: entries).last?.id, "fixture")
        let blocked = AppEntry(id: "blocked", title: "Blocked", systemImage: "star", route: .usage)
        XCTAssertFalse(
            AppRegistry.listedAtNight(for: owner(), in: AppRegistry.all + [blocked]).contains { $0.id == "blocked" })
    }

    func testAGuestSeesOnlyWhatTheirRoleAdmits() {
        XCTAssertEqual(
            AppRegistry.listedAtNight(for: guest()).map(\.id), ["quick-actions", "alarm", "weather", "camera-import"])
        XCTAssertEqual(
            AppRegistry.listed(for: .unknown).map(\.id), ["quick-actions", "camera-import", "usage"],
            "until the role is known only what needs none")
    }

    func testTheAppsListIsTheOrderItWasInBeforeTheRegistryDrewIt() {
        XCTAssertEqual(
            AppRegistry.listed(for: owner()).map(\.id),
            [
                "quick-actions", "me", "arc", "notes", "scheduler", "alarm", "weather", "canteen", "camera-import",
                "usage", "decisions", "browser",
            ])
    }

    // MARK: The gate

    func testWhileAwakeEveryRouteGoesWhereItIsSent() {
        let router = Router(gate: .ready)
        router.sleepMode = sleepStore(asleep: false)
        router.push(.session(id: "a"))
        router.push(.computerCall)
        XCTAssertEqual(router.path, [.session(id: "a"), .computerCall])
    }

    func testWhileAsleepASessionSurfaceLeavesTheAppOnTheSleepScreen() {
        let router = Router(gate: .ready)
        router.sleepMode = sleepStore(asleep: true)
        router.push(.notes)
        XCTAssertEqual(router.path, [.notes], "an allowed screen is pushed as ever")

        router.push(.createSession)
        XCTAssertEqual(router.path, [], "what a new session action pushes")
        router.push(.notes)
        router.surface(.computerCall)
        XCTAssertEqual(router.path, [], "what Computer's tile reaches")
        router.push(.me)
        router.replace(with: [.notes, .session(id: "a")])
        XCTAssertEqual(router.path, [], "a link into a session")
        XCTAssertFalse(router.openSession(id: "a", messageID: 3))
        XCTAssertEqual(router.path, [], "a tapped notification")
        router.openNote(id: "n1")
        XCTAssertEqual(router.path, [.notes, .note(id: "n1")], "a link into a note")
    }

    func testEveryDeepLinkIntoTheSessionsEndsOnTheSleepScreen() {
        let router = Router(gate: .ready)
        router.sleepMode = sleepStore(asleep: true)
        for link: DeepLink in [
            .session(id: "a"), .createSession, .notification(id: "n"), .browser(name: nil), .browser(name: "b"),
        ] {
            router.push(.notes)
            router.replace(with: link.routes)
            XCTAssertEqual(router.path, [], "\(link)")
        }
        for link: DeepLink in [.quickActions, .alarm(id: nil), .weather, .notesList, .note(id: "n")] {
            router.replace(with: link.routes)
            XCTAssertEqual(router.path, link.routes, "\(link)")
        }
    }

    func testWhenSleepBeginsTheSessionSurfacesLeaveThePath() {
        let router = Router(gate: .ready)
        let sleep = sleepStore(asleep: false)
        router.sleepMode = sleep
        router.push(.notes)
        router.push(.session(id: "a"))
        router.sleepBegan()
        XCTAssertEqual(router.path, [], "the app lands on the sleep screen")

        router.push(.notes)
        router.sleepBegan()
        XCTAssertEqual(router.path, [.notes], "nothing of the agents was on show")
    }

    // MARK: Quick Actions

    func testEveryQuickActionThatStartsASessionIsPutAwayAndTheOthersKeepWorking() {
        for action in QuickAction.allCases where action.isSessionAction {
            XCTAssertTrue(action.isNightBlocked, action.rawValue)
        }
        XCTAssertTrue(QuickAction.computer.isNightBlocked, "Computer is a call into the agents")
        for kept in [QuickAction.selfReport, .me, .findNote, .newNote, .shortcut1, .shortcut2, .shortcut3] {
            XCTAssertFalse(kept.isNightBlocked, kept.rawValue)
        }
    }

    func testTheGridKeepsItsLayoutWhileAsleep() {
        // The layout is one list whatever the hour: only the tiles' state changes.
        XCTAssertEqual(
            QuickActionLayout.summary,
            "selfReport,me,more|computer,home,ultrafast|mailverdict,homeCall,ultrafastCamera|-,-,ultrafastCall")
    }

    func testASessionActionLandsOnTheSleepScreen() {
        let router = Router(gate: .ready)
        router.sleepMode = sleepStore(asleep: true)
        // What each blocked tile pushes or presents: the route the action reaches.
        let reached: [QuickAction: Route] = [
            .computer: .computerCall, .home: .createSession, .ultrafast: .createSession,
            .homeCall: .createSession, .ultrafastCamera: .createSession, .ultrafastCall: .createSession,
            .fastSession: .createSession, .fastCall: .createSession,
        ]
        for (action, route) in reached {
            XCTAssertTrue(action.isNightBlocked)
            router.push(.quickActions)
            router.push(route)
            XCTAssertEqual(router.path, [], action.rawValue)
        }
        router.push(.quickActions)
        XCTAssertEqual(router.path, [.quickActions], "the screen itself opens during the window")
    }
}
