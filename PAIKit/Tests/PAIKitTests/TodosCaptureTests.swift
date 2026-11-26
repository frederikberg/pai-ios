import Foundation
import XCTest

@testable import PAIKit

/// Answers parse calls in the order the test releases them, so an older answer can be made to
/// arrive after a newer one.
private actor GatedParser {
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []
    private var asked: Set<String> = []
    private var askWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    func parse(_ text: String) async throws -> TodosParseAnswer {
        asked.insert(text)
        askWaiters.removeValue(forKey: text)?.resume()
        if !released.contains(text) {
            await withCheckedContinuation { gates[text] = $0 }
        }
        return try TodosWireSamples.decode(TodosParseAnswer.self, "parse-fields")
    }

    func release(_ text: String) {
        released.insert(text)
        gates.removeValue(forKey: text)?.resume()
    }

    /// Returns once `text` has been asked about.
    func waitUntilAsked(_ text: String) async {
        guard !asked.contains(text) else { return }
        await withCheckedContinuation { askWaiters[text] = $0 }
    }
}

@MainActor
final class TodosCaptureTests: XCTestCase {

    /// A real scheduler: a door's wait for the verdict is a real timeout.
    private func makeStore(_ storage: any TodosStorage = InMemoryTodosStorage()) -> TodosStore {
        let clock = TodosTestClock("2026-11-26T10:00:00+01:00")
        return TodosStore(storage: storage, now: { clock.now })
    }

    /// The add sheet's preview: a slower answer for older text never replaces the answer for
    /// what is typed now, and the add uses an answer only for exactly the text being added.
    func testAnOlderParseNeverReplacesANewerOne() async throws {
        let parser = GatedParser()
        let draft = TodoCaptureDraft { try await parser.parse($0) }
        draft.text = "Call the plumber"
        let older = Task { await draft.read() }
        await parser.waitUntilAsked("Call the plumber")
        draft.text = "Call the plumber tomorrow"
        await parser.release("Call the plumber tomorrow")
        await draft.read()
        await parser.release("Call the plumber")
        await older.value

        XCTAssertEqual(draft.answerText, "Call the plumber tomorrow")
        XCTAssertNotNil(draft.answer(for: "Call the plumber tomorrow"))
        XCTAssertNil(draft.answer(for: "Call the plumber"))
        XCTAssertFalse(draft.chips.isEmpty)
    }

    /// What Siri and Shortcuts run: online the answer names the todo the server made; offline
    /// the todo waits on the phone and the answer says so.
    func testADoorThatWaitsSaysWhatBecameOfTheTodo() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()

        let added = await store.captureAndWait(
            text: "Call the plumber tomorrow 17:00 #home p1", source: .shortcut, timeout: 30)
        XCTAssertTrue(added.added)
        XCTAssertEqual(added.message(keeper: .app), "Added \u{201C}Call the plumber\u{201D}.")

        await server.set(network: .down)
        let waiting = await store.captureAndWait(text: "Buy stamps", source: .shortcut, timeout: 0.05)
        XCTAssertEqual(waiting.settlement, .waiting)
        XCTAssertEqual(store.queue.count, 1)
        XCTAssertEqual(waiting.message(keeper: .app), "Saved on this iPhone. It is added once there is a connection.")
    }

    /// Words longer than a title keep everything: the first line is the title, the rest the body.
    func testSpokenWordsBeyondATitleBecomeTheBody() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        let long = String(repeating: "very long words ", count: 40)
        let changeId = store.capture(text: "Pack for the trip\nsocks\nraincoat")
        let longId = store.capture(text: long)
        _ = await store.settled(changeId, timeout: 30)
        _ = await store.settled(longId, timeout: 30)

        let created = await server.createdOps.values
        let pack = created.first { $0.string("title") == "Pack for the trip" }
        XCTAssertEqual(pack?.string("body"), "socks\nraincoat")
        let cut = try XCTUnwrap(created.first { $0.string("title")?.hasPrefix("very long") == true })
        XCTAssertLessThanOrEqual(cut.string("title")?.count ?? .max, 500)
        XCTAssertEqual(cut.string("body"), long.trimmingCharacters(in: .whitespaces))
    }

    /// The share sheet's Todo goes through the same outbox: a shared link becomes a todo with the
    /// link attached; one that could not go out waits in the sheet's own queue and is sent the
    /// next time the sheet opens.
    func testASharedLinkBecomesATodoAndWaitsForTheNextShare() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeTodosServer()
        await server.set(network: .down)

        let first = ShareTodoStore(sharedText: nil, link: "https://example.org/recipe", storageRoot: root)
        first.start(server)
        XCTAssertTrue(first.canAdd)
        await first.add(timeout: 0.05)
        guard case .done(let outcome) = first.phase else { return XCTFail("\(first.phase)") }
        XCTAssertEqual(outcome.settlement, .waiting)

        await server.set(network: .up)
        let next = ShareTodoStore(sharedText: "Read later\nfrom the bus", link: nil, storageRoot: root)
        XCTAssertEqual(next.text, "Read later")
        XCTAssertEqual(next.waitingFromEarlier, 1)
        next.start(server)
        await next.todos.drain()

        let created = await server.createdOps.values
        let fromLink = try XCTUnwrap(created.first)
        XCTAssertEqual(fromLink.string("title"), "https://example.org/recipe")
        XCTAssertEqual(
            fromLink.decoded("links", as: [TodoLinkSpec].self), [.url("https://example.org/recipe")])
        XCTAssertTrue(next.todos.queue.isEmpty)
        let sources = await server.todos.values.map(\.created.source)
        XCTAssertEqual(sources, ["share"])
    }

    /// The control and the Home Screen quick action reach the add sheet through this link.
    func testTheNewTodoLinkRoundTrips() throws {
        let url = try XCTUnwrap(DeepLink.newTodo.url)
        XCTAssertEqual(DeepLink.from(url: url), .newTodo)
        XCTAssertTrue(DeepLink.newTodo.dismissesOverlays)
    }
}
