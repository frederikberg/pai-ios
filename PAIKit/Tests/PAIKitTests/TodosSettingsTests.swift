import Foundation
import XCTest

@testable import PAIKit

/// The quick switcher, the settings' default-nudge editing and list rules, and settings changes
/// reaching `/me`.
@MainActor
final class TodosSettingsTests: XCTestCase {

    private func entry(_ id: String, _ title: String, _ page: TodoPage) -> TodoBrowse.Entry {
        TodoBrowse.Entry(
            id: id, title: title, identity: TodoIdentity(icon: .list, color: .slate), count: nil, locked: false,
            page: page)
    }

    private var browse: TodoBrowse {
        TodoBrowse(
            favourites: [entry("v1", "Today", .view("v1")), entry("v2", "Upcoming", .view("v2"))],
            moreViews: [entry("v3", "Grocery run", .view("v3")), entry("v4", "Timeshares", .view("v4"))],
            lists: [
                entry("l1", "Personal", .list("l1")), entry("l2", "Groceries", .list("l2")),
                entry("l3", "Flat share", .list("l3")), entry("l4", "Äpfel", .list("l4")),
            ],
            tags: [
                entry("tag:groceries/bulk", "groceries/bulk", .tag("groceries/bulk")),
                entry("tag:home", "home", .tag("home")),
            ],
            tagsFolded: false)
    }

    /// A few letters go to the best match first: its whole name, then its start, then a word in
    /// it, views before lists before tags, case and accents aside; nothing typed offers the
    /// favourites and the lists.
    func testTheSwitcherPutsTheBestMatchFirst() async throws {
        let titles = { (query: String) in TodoSwitcher.hits(self.browse, query: query).map(\.title) }
        XCTAssertEqual(titles("Groc"), ["Grocery run", "Groceries", "groceries/bulk"])
        XCTAssertEqual(TodoSwitcher.hits(browse, query: "groceries").first?.page, .list("l2"), "the whole name first")
        XCTAssertEqual(titles("share"), ["Flat share", "Timeshares"], "a word's start before the middle of one")
        XCTAssertEqual(titles("bulk"), ["groceries/bulk"])
        XCTAssertEqual(titles("apf"), ["Äpfel"])
        XCTAssertEqual(titles("  TODAY "), ["Today"])
        XCTAssertEqual(titles("ers"), ["Personal"], "a match inside a word comes last but counts")
        XCTAssertEqual(titles("xyz"), [])
        XCTAssertEqual(TodoSwitcher.hits(browse, query: "sett").first?.kind, .settings)
        XCTAssertEqual(
            titles(""), ["Today", "Upcoming", "Personal", "Groceries", "Flat share", "Äpfel"])
    }

    /// The defaults as they are edited go out whole, in the shape the server answers with.
    func testDefaultNudgesAreEditedAndSentWhole() async throws {
        let me = try TodosWireSamples.decode(TodosMeAnswer.self, "me-default-nudges")
        let captured = try XCTUnwrap(me.prefs?.defaultNudges)
        let op = TodoSettingsOps.defaultNudges(captured)
        XCTAssertEqual(op.name, "prefs.set")
        // The captured answer carries nulls for the absent half; the op leaves it out.
        let sample = try TodosWireSamples.decode([String: PaiJSONValue].self, "me-default-nudges")
        guard case .object(let prefs) = sample["prefs"], case .object(let sent) = op.fields["default_nudges"] else {
            return XCTFail("shapes")
        }
        guard case .object(let answered) = prefs["default_nudges"] else { return XCTFail("answer") }
        func withoutNulls(_ value: PaiJSONValue?) -> PaiJSONValue {
            guard case .array(let items) = value else { return .null }
            return .array(
                items.map {
                    guard case .object(let fields) = $0 else { return $0 }
                    return .object(fields.filter { $0.value != .null })
                })
        }
        for kind in ["timed", "day", "deadline"] {
            XCTAssertEqual(sent[kind], withoutNulls(answered[kind]), kind)
        }

        typealias Edit = TodoNudgeDefaultsEdit
        var nudges = TodoDefaultNudges(timed: [], day: [], deadline: [])
        for _ in 0..<5 { nudges = Edit.adding(nudges, .day) }
        XCTAssertEqual(Edit.entries(nudges, .day).count, 3, "three at most")
        XCTAssertEqual(Edit.entries(nudges, .day).first, TodoDefaultNudges.Entry(days: 1, time: "17:00"))
        nudges = Edit.changing(nudges, .day, at: 1, to: TodoDefaultNudges.Entry(days: 0, time: "08:30"))
        nudges = Edit.removing(nudges, .day, at: 0)
        XCTAssertEqual(Edit.entries(nudges, .day).first, TodoDefaultNudges.Entry(days: 0, time: "08:30"))
        XCTAssertEqual(Edit.words(TodoDefaultNudges.Entry(days: 0, time: "08:30")), "On the day at 08:30")

        let hour = TodoDefaultNudges.Entry(minutes: 120)
        XCTAssertEqual(Edit.unit(of: hour), .hours)
        XCTAssertEqual(Edit.amount(of: hour), 2)
        XCTAssertEqual(Edit.words(hour), "2 hours before the time")
        XCTAssertEqual(Edit.entry(unit: .minutes, amount: 2, keepingTimeOf: hour), TodoDefaultNudges.Entry(minutes: 2))
        XCTAssertEqual(
            Edit.entry(unit: .days, amount: 99, keepingTimeOf: TodoDefaultNudges.Entry(days: 1, time: "09:15")),
            TodoDefaultNudges.Entry(days: 60, time: "09:15"), "held to the server's range, its time kept")
        XCTAssertEqual(
            Edit.entry(unit: .hours, amount: 999, keepingTimeOf: hour), TodoDefaultNudges.Entry(minutes: 20160))
        XCTAssertEqual(Edit.entry(unit: .days, amount: 1, keepingTimeOf: hour).time, "17:00")
    }

    /// Only an owner of a shared list changes its people, and never away its last owner.
    func testOnlyAnOwnerManagesPeopleAndTheLastOwnerStays() async throws {
        let sample = try TodosWireSamples.decode(TodosMeAnswer.self, "me")
        let personal = try XCTUnwrap(sample.lists.first)
        XCTAssertFalse(TodoListRules.canManageMembers(personal), "a personal list is nobody else's")
        let owner = try XCTUnwrap(personal.members.first)
        XCTAssertTrue(TodoListRules.isLastOwner(owner, of: personal))
        let people = [
            TodoPerson(principal: owner.principal, userId: "u0", displayName: "Me"),
            TodoPerson(principal: "user:b", userId: "ub", displayName: "Bea"),
            TodoPerson(principal: "user:a", userId: "ua", displayName: "Al"),
        ]
        XCTAssertEqual(TodoListRules.candidates(people, for: personal).map(\.displayName), ["Al", "Bea"])
        XCTAssertTrue(TodoListRules.looksLikeEmail(" sam@example.org "))
        XCTAssertFalse(TodoListRules.looksLikeEmail("sam@example"))
        XCTAssertNil(TodoSettingsOps.listRename(personal, "  "))
        XCTAssertNil(TodoSettingsOps.listRename(personal, personal.name))
        XCTAssertEqual(TodoSettingsOps.deadlineLeadDays(400).fields["deadline_lead_days"], .number(365))
    }

    /// A settings change reads `/me` again once applied, since the feed skips one's own changes.
    func testASettingsChangeReadsMeAgain() async throws {
        let server = FakeTodosServer()
        let clock = TodosTestClock("2026-11-27T10:00:00+01:00")
        let store = TodosStore(storage: InMemoryTodosStorage(), now: { clock.now })
        store.connect(server)
        await store.refresh()
        // The same change sent plainly: whatever `/me` reads the send itself makes.
        let plainStart = await server.meReads
        let plain = store.submit([TodoSettingsOps.timezone("Europe/Lisbon")])
        guard case .applied = await store.settled(plain, timeout: 30) else { return XCTFail("not applied") }
        let plainReads = await server.meReads - plainStart

        let start = await server.meReads
        guard case .applied = await store.applySettings([TodoSettingsOps.timezone("Europe/Berlin")]) else {
            return XCTFail("not applied")
        }
        let reads = await server.meReads - start
        XCTAssertEqual(reads, plainReads + 1)
    }
}

/// Where the Shortcuts picker and the Quick Actions tiles find Todos' views and lists.
@MainActor
final class TodosPlacesTests: XCTestCase {
    func testThePickerListsEveryViewThenEveryOpenList() async throws {
        let me = try TodosWireSamples.decode(TodosMeAnswer.self, "me")
        let places = TodoBrowse.places(me)
        let views = me.views.sorted { $0.rank < $1.rank }
        let lists = me.lists.filter { !$0.archived }
        XCTAssertFalse(views.isEmpty)
        XCTAssertEqual(places.map(\.page), views.map { .view($0.id) } + lists.map { .list($0.id) })
        XCTAssertEqual(places.map(\.title), views.map(\.name) + lists.map(\.name))
        for place in places { XCTAssertEqual(TodoPage(key: place.page.key), place.page, "stored by its key") }
        XCTAssertNil(TodoPage(key: "view:"))
        XCTAssertNil(TodoPage(key: "board:x"))
    }

    /// The page last shown is kept, and a request for the full Desk or the switcher is taken once.
    func testTheLastPageIsKeptAndARequestIsTakenOnce() async throws {
        let storage = SettingsInMemoryKeyValueStore()
        let place = TodosPlace(storage: storage)
        XCTAssertNil(place.lastPage)
        place.shown(.list("L1"))
        XCTAssertEqual(TodosPlace(storage: storage).lastPage, .list("L1"))
        place.requestFullDesk()
        XCTAssertTrue(place.takeFullDesk())
        XCTAssertFalse(place.takeFullDesk())
        place.requestSwitcher()
        XCTAssertTrue(place.takeSwitcher())
        XCTAssertFalse(place.takeSwitcher())
    }

    /// A view dragged in the settings list is placed before the row it was dropped above, or
    /// after the last one; a drop where it already stands sends nothing.
    func testADraggedViewIsPlacedWhereItWasDropped() async throws {
        let views = try TodosWireSamples.decode(TodosMeAnswer.self, "me").views.sorted { $0.rank < $1.rank }
        try XCTSkipIf(views.count < 3, "the sample holds too few views")
        let down = try XCTUnwrap(TodoSettingsOps.viewMove(views, from: 0, to: 2))
        XCTAssertEqual(down.string("id"), views[0].id)
        XCTAssertEqual(down.object("position")?.string("before"), views[2].id)
        let last = try XCTUnwrap(TodoSettingsOps.viewMove(views, from: 0, to: views.count))
        XCTAssertEqual(last.object("position")?.string("after"), views[views.count - 1].id)
        let up = try XCTUnwrap(TodoSettingsOps.viewMove(views, from: 2, to: 0))
        XCTAssertEqual(up.object("position")?.string("before"), views[0].id)
        XCTAssertNil(TodoSettingsOps.viewMove(views, from: 1, to: 1))
        XCTAssertNil(TodoSettingsOps.viewMove(views, from: 1, to: 2))
    }

    /// A todo cannot be put under itself, its present parent or anything inside it.
    func testATodoIsNotOfferedAPlaceInsideItself() async throws {
        let server = FakeTodosServer()
        try await server.seed(id: "a", title: "A")
        try await server.seed(id: "b", title: "B", parent: "a")
        try await server.seed(id: "c", title: "C", parent: "b")
        try await server.seed(id: "d", title: "D")
        let todos = await server.todos
        let b = try XCTUnwrap(todos["b"])
        func allowed(_ id: String) -> Bool {
            TodoParentChoice.allowed(todos[id]!, moving: b, todos: todos, lists: [])
        }
        XCTAssertTrue(allowed("d"))
        XCTAssertFalse(allowed("a"), "it is there already")
        XCTAssertFalse(allowed("b"))
        XCTAssertFalse(allowed("c"), "its own subtask")
    }
}
