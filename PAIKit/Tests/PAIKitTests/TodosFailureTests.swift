import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What a change of person, a failed re-read, a slow or missing network, a server error and a
/// full disk do to the queue and to what the doors say.
@MainActor
final class TodosFailureTests: XCTestCase {

    private func makeStore(_ storage: any TodosStorage = InMemoryTodosStorage(), held: Bool = true) -> TodosStore {
        let clock = TodosTestClock("2026-11-26T10:00:00+01:00")
        return held
            ? TodosStore(storage: storage, scheduler: HeldScheduler(), now: { clock.now })
            : TodosStore(storage: storage, now: { clock.now })
    }

    /// A phone whose sign-in expired and was signed in again as someone else never sends the
    /// first person's queued change on the second person's credential, even with the first
    /// person still in the cache.
    func testAQueuedChangeNeverGoesOutAsAnotherPerson() async throws {
        let sample = try TodosWireSamples.decode(TodosMeAnswer.self, "me")
        let storage = InMemoryTodosStorage()
        storage.saveCache(TodosCache(me: sample))
        storage.saveQueue([
            TodosQueuedChange(
                changeId: "0190a000-0000-7000-8000-000000000101", summary: nil,
                ops: [.create(id: "0190a000-0000-7000-8000-0000000001aa", title: "The first person's")],
                source: "ios", principal: sample.principal, queuedAt: "2026-11-26T09:00:00+00:00")
        ])
        let server = FakeTodosServer()
        await server.signIn(as: "user:someone-else")
        let store = makeStore(storage)
        store.connect(server)
        await store.drain()
        await store.refresh()

        let applied = await server.appliedLog
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(store.queue.map(\.changeId), ["0190a000-0000-7000-8000-000000000101"])
        XCTAssertEqual(store.me?.principal, "user:someone-else")

        let theirs = store.submit([.create(id: TodosStore.uuidv7(), title: "The second person's")])
        await store.drain()
        let appliedAs = await server.appliedAs
        XCTAssertEqual(appliedAs[theirs], "user:someone-else")
        XCTAssertEqual(store.queue.count, 1)
    }

    /// When the read the feed asked for fails, the next catch-up asks again.
    func testAFailedReReadIsAskedForAgain() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        store.connect(server)
        await store.refresh()

        let id = "11111111-0000-7000-8000-0000000000ee"
        try await server.seed(id: id, title: "Made on the laptop")
        let seq = await server.nextSeq()
        await server.publish(
            TodoEvent(
                seq: seq, changeId: "0190a000-0000-7000-8000-0000000000cc", entity: "todo", entityId: id, todoId: id,
                listId: nil, op: "create", before: nil, after: nil))
        await server.failNextMe()
        await store.catchUp()
        XCTAssertNil(store.todos[id])

        await store.catchUp()
        XCTAssertEqual(store.todos[id]?.title, "Made on the laptop")
    }

    /// A door's wait covers reading who is signed in: the capture is on disk at once, and the
    /// answer comes within the wait even while `/me` hangs.
    func testADoorQueuesAtOnceAndAnswersWithinItsWaitWhileMeHangs() async throws {
        let storage = InMemoryTodosStorage()
        let server = FakeTodosServer()
        await server.holdMe()
        let store = makeStore(storage, held: false)
        store.connect(server)
        let release = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await server.releaseMe()
        }
        let started = Date()
        let outcome = await store.captureAndWait(text: "Ring the landlord", source: .shortcut, timeout: 0.3)
        let waited = Date().timeIntervalSince(started)
        XCTAssertLessThan(waited, 2)
        XCTAssertEqual(outcome.settlement, .waiting)
        XCTAssertEqual(storage.loadQueue().first?.capture?.text, "Ring the landlord")
        await release.value
    }

    /// Without a network the door hears so at once, not after its whole wait.
    func testADoorHearsAtOnceThatThereIsNoNetwork() async throws {
        let server = FakeTodosServer()
        let store = makeStore(held: false)
        store.connect(server)
        await store.refresh()
        await server.set(network: .down)
        let started = Date()
        let outcome = await store.captureAndWait(text: "Buy stamps", source: .shortcut, timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(outcome.settlement, .waiting)
    }

    /// A server error is sent again; one that keeps failing is refused with its words told.
    func testAServerErrorIsRetriedThenRefusedWithItsWords() async throws {
        let server = FakeTodosServer()
        let store = makeStore()
        var told: [String] = []
        store.onRefusal = { refusal, words in told.append(refusal.told(about: words)) }
        store.connect(server)
        let serverError = PaiError.http(statusCode: 500, reason: "Internal Server Error")
        await server.failNextApplies([serverError, serverError])
        let hiccup = store.submit([.create(id: TodosStore.uuidv7(), title: "Book the dentist")])
        // Each round sends at least once more; a retry already on its way joins the round.
        for _ in 0..<10 where !store.queue.isEmpty {
            store.retryNow()
            await store.drain()
        }
        let applied = await server.appliedLog
        XCTAssertEqual(applied, [hiccup])

        await server.failNextApplies(Array(repeating: serverError, count: 10))
        store.submit([.create(id: TodosStore.uuidv7(), title: "Renew the passport")])
        for _ in 0..<20 where !store.queue.isEmpty {
            store.retryNow()
            await store.drain()
        }
        let attempts = await server.applyCalls
        XCTAssertEqual(attempts, 3 + TodosStore.serverErrorAttempts, "sent a bounded number of times")
        XCTAssertTrue(store.queue.isEmpty)
        XCTAssertEqual(store.refused.map(\.text), ["Renew the passport"])
        XCTAssertEqual(told.count, 1)
        XCTAssertTrue(told.first?.contains("Renew the passport") == true)
    }

    /// A queue that could not reach the disk is said, never promised as saved.
    func testAQueueThatDidNotReachTheDiskIsNotCalledSaved() async throws {
        let server = FakeTodosServer()
        await server.set(network: .down)
        let store = makeStore(FailingQueueStorage(), held: false)
        store.connect(server)
        let outcome = await store.captureAndWait(text: "Call grandma", source: .shortcut, timeout: 5)
        XCTAssertTrue(store.unsaved)
        XCTAssertFalse(outcome.saved)
        XCTAssertEqual(outcome.message(keeper: .intent), "Could not save this todo on the iPhone. Add it again in PAI.")
    }

    /// Words that are only spaces (an empty Shortcuts variable) queue nothing.
    func testEmptyWordsQueueNothing() async throws {
        let store = makeStore()
        store.connect(FakeTodosServer())
        let outcome = await store.captureAndWait(text: "  \n ", source: .shortcut, timeout: 1)
        guard case .refused(let refusal) = outcome.settlement else { return XCTFail("\(outcome)") }
        XCTAssertEqual(refusal.code, "empty")
        XCTAssertTrue(store.queue.isEmpty)
    }

    /// A second Add before the sheet has left finds nothing to add.
    func testTheAddSheetLineIsTakenOnce() async throws {
        let draft = TodoCaptureDraft { _ in try TodosWireSamples.decode(TodosParseAnswer.self, "parse-fields") }
        draft.text = "Water the plants"
        XCTAssertEqual(draft.take()?.text, "Water the plants")
        XCTAssertNil(draft.take())
    }
}
