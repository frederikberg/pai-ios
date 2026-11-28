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

    /// Typing on does not unmark what was read: the answer for the older line stays, its words
    /// marked where they sit now, until the next answer lands; and an answer still on its way
    /// when the line is added never lands on the empty line after it.
    func testWhatWasReadStaysMarkedWhileTypingGoesOn() async throws {
        let parser = GatedParser()
        let draft = TodoCaptureDraft { try await parser.parse($0) }
        let line = "Call the plumber tomorrow 17:00 #home p1"
        draft.text = line
        await parser.release(line)
        await draft.read()
        XCTAssertEqual(draft.marks.count, 3)

        draft.text = "Please c" + line.dropFirst()
        XCTAssertFalse(draft.chips.isEmpty, "the chips stay while the next answer is on its way")
        XCTAssertEqual(draft.marks.map(\.kind), ["when", "tag", "horizon"])
        let units = Array(draft.text.utf16)
        XCTAssertEqual(
            draft.marks.map { String(decoding: units[$0.start..<$0.end], as: UTF16.self) },
            ["tomorrow 17:00", "#home", "p1"])
        XCTAssertNil(draft.answer(for: draft.text), "an add never uses an answer for other text")

        let late = Task { await draft.read() }
        await parser.waitUntilAsked(draft.text)
        let asked = draft.text
        XCTAssertNotNil(draft.take())
        await parser.release(asked)
        await late.value
        XCTAssertNil(draft.answer)
        XCTAssertTrue(draft.marks.isEmpty)
    }

    /// The marks land where the web app's own `carryTokens` puts them
    /// (`Resources/todos/web-carry-vectors.json`).
    func testTokensAreCarriedAsTheWebCarriesThem() throws {
        struct Case: Decodable {
            struct Out: Decodable {
                let tokens: [TodoParseToken]
                let complete: Bool
            }

            let from: String
            let to: String
            let tokens: [TodoParseToken]
            let out: Out
        }
        struct Vectors: Decodable { let cases: [Case] }
        let vectors = try TodosWireSamples.decode(Vectors.self, "web-carry-vectors")
        XCTAssertGreaterThanOrEqual(vectors.cases.count, 20)
        for case_ in vectors.cases {
            let carried = TodoLineTokens.carry(from: case_.from, to: case_.to, tokens: case_.tokens)
            XCTAssertEqual(carried.tokens, case_.out.tokens, "\(case_.from) -> \(case_.to)")
            XCTAssertEqual(carried.complete, case_.out.complete, "\(case_.from) -> \(case_.to)")
        }
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
        XCTAssertEqual(
            waiting.message(keeper: .intent), "Saved on this iPhone. Open PAI when there is a connection to send it.")
    }

    /// Lines after the first are the body.
    func testLinesAfterTheFirstBecomeTheBody() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        let changeId = store.capture(text: "Pack for the trip\nsocks\nraincoat")
        _ = await store.settled(changeId, timeout: 30)

        let created = await server.createdOps.values
        let pack = created.first { $0.string("title") == "Pack for the trip" }
        XCTAssertEqual(pack?.string("body"), "socks\nraincoat")
    }

    /// The share sheet's Todo goes through the same outbox: a shared link becomes a todo with the
    /// link attached. One the server did not take keeps its words in the sheet, and Try again with
    /// the same words resends the same change, so a lost answer never makes two todos.
    func testASharedLinkBecomesATodoAndATryAgainNeverMakesTwo() async throws {
        let server = FakeTodosServer()
        await server.set(network: .down)
        let share = ShareTodoStore(sharedText: nil, link: "https://example.org/recipe")
        share.start(server)
        XCTAssertTrue(share.canAdd)
        await share.add(timeout: 30)
        guard case .notAdded(let outcome) = share.phase else { return XCTFail("\(share.phase)") }
        XCTAssertEqual(outcome.settlement, .waiting)
        XCTAssertTrue(share.canAdd, "the words stay, ready to try again")

        await server.set(network: .up)
        await server.loseTheNextAnswer()
        await share.add(timeout: 30)
        guard case .notAdded = share.phase else { return XCTFail("\(share.phase)") }
        await share.add(timeout: 30)
        guard case .added = share.phase else { return XCTFail("\(share.phase)") }

        let created = await server.createdOps.values
        XCTAssertEqual(created.count, 1)
        let fromLink = try XCTUnwrap(created.first)
        XCTAssertEqual(fromLink.string("title"), "https://example.org/recipe")
        XCTAssertEqual(fromLink.decoded("links", as: [TodoLinkSpec].self), [.url("https://example.org/recipe")])
        let sources = await server.todos.values.map(\.created.source)
        XCTAssertEqual(sources, ["share"])
    }

    /// The control and the Home Screen quick action reach the add sheet through this link.
    func testTheNewTodoLinkRoundTrips() throws {
        let url = try XCTUnwrap(DeepLink.newTodo.url)
        XCTAssertEqual(DeepLink.from(url: url), .newTodo)
        XCTAssertTrue(DeepLink.newTodo.dismissesOverlays)
        XCTAssertEqual(DeepLink.from(url: try XCTUnwrap(DeepLink.todosHome.url)), .todosHome)
        XCTAssertEqual(
            DeepLink.from(webURL: try XCTUnwrap(URL(string: "https://pai.example.org/apps/todos"))), .todosHome)
        XCTAssertEqual(DeepLink.todosHome.routes, [.todos])
    }
}
