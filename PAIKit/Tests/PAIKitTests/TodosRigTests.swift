import Foundation
import XCTest

@testable import PAIKit

/// The engine against a real Todos server: a rig stack's persona address in `TODOS_RIG_URL`
/// (`bun e2e/todos/stack.ts` in pai-cloud prints one per persona; each signs its requests in by
/// itself). Skipped without it, so the free checks never need a server.
@MainActor
final class TodosRigTests: XCTestCase {

    /// Capture, tick, untick and the desk through the real client, then read back through the
    /// server's own query and through a relaunch from the cache.
    func testTheEngineAgreesWithARealServer() async throws {
        guard let url = ProcessInfo.processInfo.environment["TODOS_RIG_URL"], !url.isEmpty else {
            throw XCTSkip("TODOS_RIG_URL is not set")
        }
        let client = PaiApiClient(requestFactory: try PaiRequestFactory(baseURL: url, deviceName: "rig") { nil })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("todos-rig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileTodosStorage(
            rootURL: root.appendingPathComponent("outbox"), cacheDirectory: root.appendingPathComponent("cache"))
        let store = TodosStore(storage: storage)
        store.connect(client)
        await store.refresh()
        XCTAssertNotNil(store.me, "the rig answered /me")

        let word = "rigcheck\(Int.random(in: 1000...9999))"
        let added = store.capture(text: "Post the \(word) letter tomorrow #errands *", source: .shortcut)
        guard case .applied(let result?) = await store.settled(added, timeout: 30) else {
            return XCTFail("the capture was not applied")
        }
        let todo = try XCTUnwrap(result.todos.first)
        XCTAssertEqual(todo.title, "Post the \(word) letter")
        XCTAssertEqual(todo.tags, ["errands"])
        XCTAssertNotNil(todo.when)
        XCTAssertEqual(todo.created.source, "shortcut")
        await store.drain()
        XCTAssertTrue(store.deskItems.contains { $0.todoId == todo.id }, "the parser's * put it on the desk")

        let tick = try XCTUnwrap(store.toggleDone(todoId: todo.id))
        guard case .applied = await store.settled(tick, timeout: 30) else { return XCTFail("tick") }
        XCTAssertEqual(store.todos[todo.id]?.status, .done)
        let untick = try XCTUnwrap(store.toggleDone(todoId: todo.id))
        guard case .applied = await store.settled(untick, timeout: 30) else { return XCTFail("untick") }
        let off = store.setOnDesk(todoId: todo.id, false)
        guard case .applied = await store.settled(off, timeout: 30) else { return XCTFail("desk remove") }
        await store.drain()
        XCTAssertFalse(store.deskItems.contains { $0.todoId == todo.id })

        // `is:any`: a todo meant for tomorrow is asleep, which a query leaves out by default.
        let found = try await client.todosQuery(
            TodosQueryRequest(q: "\(word) is:any", scope: nil, group: "none", tree: "flat"))
        XCTAssertEqual(found.todos.map(\.id), [todo.id])
        XCTAssertEqual(found.todos.first?.status, .open)
        XCTAssertEqual(found.todos.first?.onDesk, false)

        // The share sheet's path: words through the parser, a link attached, multi-line text kept.
        let shared = await store.captureAndWait(
            text: "Read the \(word) recipe #errands\nfrom the bus", links: [.url("https://example.org/\(word)")],
            source: .share, timeout: 30)
        guard case .applied(let sharedResult?) = shared.settlement else { return XCTFail("share capture") }
        let sharedTodo = try XCTUnwrap(sharedResult.todos.first)
        XCTAssertEqual(shared.title, "Read the \(word) recipe")
        XCTAssertEqual(sharedTodo.links.map(\.target), ["https://example.org/\(word)"])
        XCTAssertEqual(sharedTodo.bodyPreview, "from the bus")
        XCTAssertEqual(sharedTodo.created.source, "share")

        await store.refresh()
        let relaunched = TodosStore(storage: storage)
        XCTAssertEqual(relaunched.todos[todo.id]?.title, "Post the \(word) letter")
        XCTAssertTrue(relaunched.queue.isEmpty)
    }

    /// Every op the settings screens send, taken by a real server: prefs, default nudges, a list
    /// with its look, lock and people, a tag's colour, quiet, name, merge and delete, a favourite.
    func testTheSettingsOpsAreTakenByARealServer() async throws {
        guard let url = ProcessInfo.processInfo.environment["TODOS_RIG_URL"], !url.isEmpty else {
            throw XCTSkip("TODOS_RIG_URL is not set")
        }
        let client = PaiApiClient(requestFactory: try PaiRequestFactory(baseURL: url, deviceName: "rig") { nil })
        let store = TodosStore(storage: InMemoryTodosStorage())
        store.connect(client)
        await store.refresh()
        func taken(_ ops: [TodoOp?], _ what: String) async {
            let settlement = await store.applySettings(ops.compactMap { $0 })
            guard case .applied(let result?) = settlement else { return XCTFail("\(what): \(settlement)") }
            XCTAssertTrue(result.results.allSatisfy(\.ok), "\(what): \(result.results)")
        }

        await taken(
            [
                TodoSettingsOps.timezone("Europe/Lisbon"), TodoSettingsOps.dayRollover("04:00"),
                TodoSettingsOps.deadlineLeadDays(5),
            ], "general")
        XCTAssertEqual(store.me?.prefs?.timezone, "Europe/Lisbon")
        XCTAssertEqual(store.me?.prefs?.deadlineLeadDays, 5)
        var nudges = TodoDefaultNudges(timed: [], day: [], deadline: [])
        nudges = TodoNudgeDefaultsEdit.adding(nudges, .timed)
        nudges = TodoNudgeDefaultsEdit.adding(nudges, .day)
        nudges = TodoNudgeDefaultsEdit.adding(nudges, .deadline)
        await taken([TodoSettingsOps.defaultNudges(nudges)], "default nudges")
        XCTAssertEqual(store.me?.prefs?.defaultNudges, nudges)

        let listId = TodosStore.uuidv7()
        await taken([TodoSettingsOps.listCreate(id: listId, name: "Rig settings list", layout: "checklist")], "create")
        let list = try XCTUnwrap(store.lists.first { $0.id == listId })
        await taken([TodoSettingsOps.defaultList(listId)], "default list")
        XCTAssertEqual(store.me?.prefs?.defaultListId, listId)
        await taken([TodoSettingsOps.defaultList(nil)], "default list back")
        await taken(
            [
                TodoSettingsOps.listRename(list, "Rig settings list two"), TodoSettingsOps.listLayout(list, "list"),
                TodoSettingsOps.listColor(list, .sky), TodoSettingsOps.listIcon(list, .cart),
            ], "list look")
        let styled = try XCTUnwrap(store.lists.first { $0.id == listId })
        XCTAssertEqual(styled.name, "Rig settings list two")
        XCTAssertEqual(styled.color, "sky")
        await taken([TodoSettingsOps.listLocked(styled, true)], "lock")
        await taken([TodoSettingsOps.listLocked(styled, false)], "unlock")
        // An address is shared with only once someone signs in with it, which no rig persona has
        // done: the server reads the op and refuses the address, not the op's shape.
        let byEmail = await store.applySettings([
            TodoSettingsOps.share(styled, email: "nobody-yet@example.org", role: .editor)
        ])
        guard case .refused(let refusal) = byEmail else { return XCTFail("share by email: \(byEmail)") }
        XCTAssertTrue(refusal.message.contains("address"), refusal.message)
        // Someone to share with: whom the server offers, else the person the rig names in
        // `TODOS_RIG_PERSON_USER` (a persona's user id from the stack's personas.json).
        var people = await store.people()
        if people.isEmpty, let user = ProcessInfo.processInfo.environment["TODOS_RIG_PERSON_USER"], !user.isEmpty {
            people = [TodoPerson(principal: "user:\(user)", userId: user, displayName: "Rig person")]
        }
        if let person = TodoListRules.candidates(people, for: styled).first {
            await taken([TodoSettingsOps.share(styled, with: person, role: .viewer)], "share with a person")
            let shared = try XCTUnwrap(store.lists.first { $0.id == listId })
            let member = try XCTUnwrap(shared.members.first { $0.principal == person.principal })
            await taken([TodoSettingsOps.setRole(shared, of: member, to: .editor)], "role")
            await taken([TodoSettingsOps.removeMember(shared, member)], "remove")
        }
        await taken([TodoSettingsOps.listArchive(styled)], "archive")

        let word = "rigtag\(Int.random(in: 1000...9999))"
        for text in ["One #\(word)a", "Two #\(word)b"] {
            guard case .applied = await store.settled(store.capture(text: text), timeout: 30) else {
                return XCTFail("capture")
            }
        }
        await store.refresh()
        let first = try XCTUnwrap(store.me?.tags.first { $0.name == "\(word)a" })
        let second = try XCTUnwrap(store.me?.tags.first { $0.name == "\(word)b" })
        await taken([TodoSettingsOps.tagColor(first, .violet), TodoSettingsOps.tagQuiet(first, true)], "tag look")
        await taken([TodoSettingsOps.tagRename(first, "\(word)c")], "tag rename")
        let renamed = try XCTUnwrap(store.me?.tags.first { $0.name == "\(word)c" })
        XCTAssertEqual(renamed.color, "violet")
        XCTAssertTrue(renamed.quiet)
        await taken([TodoSettingsOps.tagMerge(renamed, into: second)], "merge")
        let merged = try XCTUnwrap(store.me?.tags.first { $0.name == "\(word)b" })
        await taken([TodoSettingsOps.tagDelete(merged)], "delete")
        XCTAssertNil(store.me?.tags.first { $0.name.hasPrefix(word) })

        let viewId = TodosStore.uuidv7()
        await taken(
            [
                TodoSettingsOps.viewSave(
                    id: viewId, name: "Rig view", query: "is:open", layout: TodoSettingsOps.newViewLayout, pinned: false
                )
            ], "view create")
        let made = try XCTUnwrap(store.me?.views.first { $0.id == viewId })
        await taken(
            [TodoSettingsOps.viewSave(id: viewId, name: "Rig view two", query: made.query, layout: made.layout)],
            "view rename")
        let ordered = (store.me?.views ?? []).sorted { $0.rank < $1.rank }
        let at = try XCTUnwrap(ordered.firstIndex { $0.id == viewId })
        await taken([TodoSettingsOps.viewMove(ordered, from: at, to: 0)], "view move")
        let moved = (store.me?.views ?? []).sorted { $0.rank < $1.rank }
        XCTAssertEqual(moved.first?.id, viewId)
        XCTAssertEqual(moved.first?.name, "Rig view two")
        XCTAssertEqual(moved.first?.pinned, false, "a save that names no favourite keeps it")
        await taken([TodoSettingsOps.viewDelete(try XCTUnwrap(moved.first))], "view delete")
        XCTAssertNil(store.me?.views.first { $0.id == viewId })

        let view = try XCTUnwrap(store.me?.views.first)
        await taken([TodoSettingsOps.favourite(view, !view.pinned)], "favourite")
        XCTAssertEqual(store.me?.views.first { $0.id == view.id }?.pinned, !view.pinned)
        await taken([TodoSettingsOps.favourite(view, view.pinned)], "favourite back")
    }
}
