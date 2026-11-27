import XCTest

@testable import PAIKit

final class QuickActionLayoutTests: XCTestCase {

    // MARK: The standard arrangement

    /// Every action is on the grid, in More or hidden exactly once, so none is duplicated and none
    /// is unreachable from the library.
    func testTheStandardArrangementPlacesEveryActionOnce() {
        let standard = QuickActionArrangement.standard
        let all = (standard.grid + standard.more + standard.hidden).filter { $0 != .more }
        XCTAssertEqual(all.count, QuickAction.allCases.count)
        XCTAssertEqual(Set(all), Set(QuickAction.allCases.map(QuickActionItem.action)))
    }

    func testTheStandardGridFillsTheFiveRowsWithFindNoteAndNewNoteOnIt() {
        let grid = QuickActionArrangement.standard.grid
        XCTAssertEqual(grid.count, QuickActionGrid.columns * QuickActionGrid.visibleRows)
        XCTAssertEqual(grid[2], .more, "More sits top right")
        XCTAssertTrue(grid.contains(.action(.findNote)))
        XCTAssertTrue(grid.contains(.action(.newNote)))
    }

    func testTheLibraryListsEveryActionThenTheShortcuts() {
        let shortcut = QuickActionShortcut(name: "Inbox", urlString: "https://example.com")
        let arrangement = QuickActionArrangement(grid: [], more: [], shortcuts: [shortcut])
        XCTAssertEqual(arrangement.library.count, QuickAction.allCases.count + 1)
        XCTAssertEqual(arrangement.library.last, .shortcut(shortcut.id))
        XCTAssertFalse(arrangement.library.contains(.more))
    }

    // MARK: Tile size

    func testFiveRowsFillTheViewportAndEveryTileHasTheSameHeight() {
        let height = QuickActionGrid.tileHeight(viewportHeight: 700, padding: 16, spacing: 12)
        XCTAssertEqual(height * 5 + 12 * 4 + 32, 700, accuracy: 0.001)
        XCTAssertEqual(QuickActionGrid.tileHeight(viewportHeight: 100, padding: 16, spacing: 12), 56)
    }

    // MARK: Item ids

    func testItemIdsRoundTripAndAnUnknownOneIsDropped() throws {
        let shortcut = QuickActionShortcut(name: "x", urlString: "todoist://today")
        for item in [QuickActionItem.action(.findNote), .more, .shortcut(shortcut.id)] {
            XCTAssertEqual(QuickActionItem(id: item.id), item)
        }
        let json = """
            {"grid":["home","retiredAction","shortcut:\(shortcut.id.uuidString)","shortcut:\(UUID().uuidString)"],
             "more":["more","home","newNote"],
             "shortcuts":[{"id":"\(shortcut.id.uuidString)","name":"x","urlString":"todoist://today"}],
             "seen":\(String(data: try JSONEncoder().encode(QuickAction.allCases.map(\.rawValue)), encoding: .utf8)!)}
            """
        let decoded = try JSONDecoder().decode(QuickActionArrangement.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.grid, [.action(.home), .shortcut(shortcut.id), .more])
        XCTAssertEqual(decoded.more, [.action(.newNote)], "a duplicate and the More tile leave More")
    }

    /// An action an arrangement has never seen arrives in More, where it is found; one it has
    /// seen and the person hid stays hidden, also after the arrangement is stored again.
    func testANewActionArrivesInMoreAndAHiddenOneStaysHidden() throws {
        let stored = #"{"grid":["home","more"],"more":["notes"],"shortcuts":[]}"#
        let older = try JSONDecoder().decode(QuickActionArrangement.self, from: Data(stored.utf8))
        XCTAssertEqual(
            older.more,
            [
                .action(.notes), .action(.todos), .action(.newTodo), .action(.searchTodos), .action(.todosSwitcher),
                .action(.todosDesk),
            ])
        XCTAssertEqual(older.placement(of: .action(.alarm)), .hidden, "an action it knew stays where it was")

        var hiding = older
        hiding.more.removeAll { $0 == .action(.todosDesk) }
        let again = try JSONDecoder().decode(QuickActionArrangement.self, from: JSONEncoder().encode(hiding))
        XCTAssertEqual(again.placement(of: .action(.todosDesk)), .hidden)
        XCTAssertEqual(again.more, hiding.more)
    }

    /// A Todos page tile round-trips by its page, is in the library, and goes with its page.
    func testATodosPageTileLivesWithItsPage() throws {
        let item = QuickActionItem.todosPage("list:L1")
        XCTAssertEqual(QuickActionItem(id: item.id), item)
        XCTAssertNil(QuickActionItem(id: "todos-page:nothing"))
        let store = QuickActionsStore(storage: nil)
        store.addTodosPage(.list("L1"))
        store.addTodosPage(.list("L1"))
        XCTAssertEqual(store.grid.filter { $0 == item }.count, 1)
        XCTAssertTrue(store.arrangement.library.contains(item))
        let restored = try JSONDecoder().decode(
            QuickActionArrangement.self, from: JSONEncoder().encode(store.arrangement))
        XCTAssertTrue(restored.grid.contains(item))
        store.deleteTodosPage("list:L1")
        XCTAssertFalse(store.grid.contains(item))
        XCTAssertFalse(store.arrangement.library.contains(item))
    }

    // MARK: Night

    func testShortcutsAreNeverPutAwayAtNightAndTheAppsFollowTheAppsList() {
        XCTAssertFalse(QuickActionItem.shortcut(UUID()).isNightBlocked)
        XCTAssertFalse(QuickActionItem.more.isNightBlocked)
        XCTAssertTrue(QuickActionItem.action(.home).isNightBlocked)
        for action in QuickAction.allCases {
            guard let entry = action.appEntry else { continue }
            XCTAssertEqual(action.isNightBlocked, entry.isNightBlocked, action.rawValue)
        }
        XCTAssertFalse(QuickAction.notes.isNightBlocked)
        XCTAssertTrue(QuickAction.scheduler.isNightBlocked)
    }

    func testAGuestGetsNeitherTheDiaryNorTheOwnerOnlyApps() {
        let guest = Capabilities(role: .guest)
        XCTAssertFalse(QuickAction.me.isAvailable(to: guest))
        XCTAssertFalse(QuickAction.findNote.isAvailable(to: guest))
        XCTAssertFalse(QuickAction.canteen.isAvailable(to: guest))
        XCTAssertTrue(QuickAction.alarm.isAvailable(to: guest))
        XCTAssertTrue(QuickAction.home.isAvailable(to: guest))
    }

    func testSessionActionsKnowTheirTypeAndMode() {
        XCTAssertEqual(QuickAction.fastCall.sessionType, "fast")
        XCTAssertTrue(QuickAction.fastCall.startsCall)
        XCTAssertFalse(QuickAction.fastSession.startsCall)
        for action in QuickAction.allCases where action.sessionType != nil {
            XCTAssertTrue(action.isSessionAction, "\(action)")
        }
        XCTAssertFalse(QuickAction.me.isSessionAction)
    }

    func testShortcutSubtitleNamesWhereTheLinkGoes() {
        XCTAssertEqual(QuickActionShortcut(name: "", urlString: "todoist://today").subtitle, "todoist")
        XCTAssertEqual(QuickActionShortcut(name: "", urlString: " https://example.com/a ").subtitle, "example.com")
        XCTAssertEqual(QuickActionShortcut(name: "", urlString: "").subtitle, "Set up")
        XCTAssertEqual(QuickActionShortcut(name: " ", urlString: "").title, "Shortcut")
    }
}

/// Every method is `async`: a `@MainActor` test class whose methods are all synchronous crashes
/// the Linux test runner.
@MainActor
final class QuickActionsStoreTests: XCTestCase {

    private func ids(_ items: [QuickActionItem]) -> [String] { items.map(\.summaryName) }

    func testAMovePersistsAcrossAReload() async {
        let storage = SettingsInMemoryKeyValueStore()
        let store = QuickActionsStore(storage: storage)
        let first = store.grid[0]
        store.move(in: .grid, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.grid[2], first)
        let reloaded = QuickActionsStore(storage: storage)
        XCTAssertEqual(reloaded.grid, store.grid)
        XCTAssertEqual(reloaded.grid[2], first)
    }

    func testMoveMatchesWhatAListReports() async {
        let items = ["a", "b", "c", "d"]
        XCTAssertEqual(QuickActionsStore.moved(items, from: [0], to: 4), ["b", "c", "d", "a"])
        XCTAssertEqual(QuickActionsStore.moved(items, from: [3], to: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(QuickActionsStore.moved(items, from: [1, 2], to: 4), ["a", "d", "b", "c"])
        XCTAssertEqual(QuickActionsStore.moved(items, from: [1], to: 1), items)
    }

    func testPlacementPersistsAndMoreListsExactlyTheMoreOnes() async {
        let storage = SettingsInMemoryKeyValueStore()
        let store = QuickActionsStore(storage: storage)
        store.place(.action(.findNote), in: .more)
        store.place(.action(.fastSession), in: .hidden)
        store.place(.action(.fastCall), in: .grid)
        store.place(.more, in: .hidden)

        let reloaded = QuickActionsStore(storage: storage)
        XCTAssertEqual(reloaded.placement(of: .action(.findNote)), .more)
        XCTAssertEqual(reloaded.placement(of: .action(.fastSession)), .hidden)
        XCTAssertEqual(reloaded.grid.last, .action(.fastCall))
        XCTAssertTrue(reloaded.grid.contains(.more), "the More tile cannot be hidden")
        XCTAssertEqual(
            ids(reloaded.more),
            [
                "canteen", "scheduler", "decisions", "usage", "cameraImport", "todos", "newTodo", "searchTodos",
                "todosSwitcher", "todosDesk", "findNote",
            ])
        XCTAssertEqual(ids(reloaded.hidden), ["fastSession"])
        XCTAssertEqual(reloaded.items(in: .more), reloaded.more)
    }

    func testAddingAndDeletingAShortcutPersist() async {
        let storage = SettingsInMemoryKeyValueStore()
        let store = QuickActionsStore(storage: storage)
        let today = store.addShortcut(name: "Today", urlString: "todoist://today")
        let other = store.addShortcut(name: "Other", urlString: "https://example.com")
        XCTAssertEqual(store.grid.suffix(2), [.shortcut(today.id), .shortcut(other.id)])

        var renamed = today
        renamed.name = "Now"
        store.updateShortcut(renamed)
        store.place(.shortcut(other.id), in: .more)
        store.deleteShortcut(today.id)

        let reloaded = QuickActionsStore(storage: storage)
        XCTAssertEqual(reloaded.shortcuts, [other])
        XCTAssertFalse(reloaded.grid.contains(.shortcut(today.id)))
        XCTAssertEqual(reloaded.more.last, .shortcut(other.id))
        XCTAssertNil(reloaded.shortcut(today.id))
    }

    func testANewStoreStartsFromTheStandardArrangementAndNilStorageKeepsNothing() async {
        let store = QuickActionsStore(storage: nil)
        XCTAssertEqual(store.arrangement, .standard)
        store.addShortcut(name: "x", urlString: "todoist://x")
        XCTAssertEqual(QuickActionsStore(storage: nil).arrangement, .standard)
    }

    func testResetKeepsTheShortcutsHidden() async {
        let store = QuickActionsStore(storage: SettingsInMemoryKeyValueStore())
        let shortcut = store.addShortcut(name: "x", urlString: "todoist://x")
        store.place(.action(.home), in: .hidden)
        store.resetToStandard()
        XCTAssertEqual(store.grid, QuickActionArrangement.standard.grid)
        XCTAssertEqual(store.placement(of: .shortcut(shortcut.id)), .hidden)
    }
}
