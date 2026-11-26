import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The answers in `Resources/todos/` were captured from a running Todos server (a rig stack,
/// invented content): `error-<status>-<code>.json` is the body of a refusal with that status.
enum TodosWireSamples {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Resources/todos", isDirectory: true)

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    static func names(prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }
}

final class TodosWireTests: XCTestCase {

    /// Every captured answer reads into its model. A field renamed, made required or given a new
    /// value on the server fails here, on Linux, rather than as an empty screen on the phone.
    func testTheServersAnswersDecode() throws {
        let me = try TodosWireSamples.decode(TodosMeAnswer.self, "me")
        XCTAssertFalse(me.lists.isEmpty)
        XCTAssertNotNil(me.prefs)

        let today = try TodosWireSamples.decode(TodosTodayAnswer.self, "today")
        XCTAssertTrue(today.desk.contains { $0.kind == .divider })
        XCTAssertTrue(today.desk.contains { $0.kind == .todo && today.todos[$0.todoId ?? ""] != nil })

        XCTAssertFalse(try TodosWireSamples.decode(TodosQueryAnswer.self, "query").todos.isEmpty)
        // The store's own read of every open todo: asleep ones and subtasks included.
        let open = try TodosWireSamples.decode(TodosQueryAnswer.self, "query-open")
        XCTAssertTrue(open.todos.contains { $0.repeat != nil && $0.asleep })
        XCTAssertTrue(open.todos.contains { $0.parentId != nil })

        let events = try TodosWireSamples.decode(TodosEventsAnswer.self, "events")
        XCTAssertFalse(events.events.isEmpty)

        let applies = try TodosWireSamples.names(prefix: "apply-")
        XCTAssertGreaterThanOrEqual(applies.count, 5)
        for name in applies {
            let result = try TodosWireSamples.decode(TodosApplyResult.self, name)
            XCTAssertFalse(result.results.isEmpty, name)
        }
        XCTAssertTrue(try TodosWireSamples.decode(TodosApplyResult.self, "apply-replay").replayed)

        let refusals = try TodosWireSamples.names(prefix: "error-")
        XCTAssertGreaterThanOrEqual(refusals.count, 6)
        for name in refusals {
            let body = try TodosWireSamples.decode(TodosErrorBody.self, name)
            XCTAssertFalse(body.message.isEmpty, name)
        }
        let conflict = try TodosWireSamples.decode(TodosErrorBody.self, "error-409-conflict")
        XCTAssertNotNil(conflict.current)

        for name in try TodosWireSamples.names(prefix: "parse-") {
            let answer = try TodosWireSamples.decode(TodosParseAnswer.self, name)
            XCTAssertEqual(answer.createOp.name, "todo.create", name)
        }
    }

    /// A refused write in Todos is a JSON 403 (`role`, `locked`). Read as a refused credential it
    /// would sign the whole app out on a tap at a locked list; only the proxy's plain-text 403 is
    /// one.
    func testATodosRefusalIsNotASignOutButTheProxysIs() async throws {
        let signedOut = SignOutCounter()
        let renewals = SignOutCounter()
        let client = try TodosStubProtocol.client(
            onAuthenticationFailure: { _ in signedOut.add() },
            renewCredential: { _ in
                renewals.add()
                return .rejected
            })
        let change = TodosChangeRequest(changeId: "c1", summary: nil, ops: [.complete(todo: "T-1")])

        TodosStubProtocol.reply(
            status: 403, contentType: "application/json", body: try TodosWireSamples.data("error-403-locked"))
        do {
            _ = try await client.todosApply(change, source: .ios)
            XCTFail("a refusal must throw")
        } catch {
            XCTAssertEqual((error as? TodosApiError)?.code, "locked")
            guard case .refused(let refusal) = TodosFailure.of(error) else { return XCTFail("\(error)") }
            XCTAssertEqual(refusal.code, "locked")
        }
        XCTAssertEqual(signedOut.count, 0)
        XCTAssertEqual(renewals.count, 0, "a refusal is no reason to renew the sign-in")

        TodosStubProtocol.reply(status: 403, contentType: "text/plain", body: Data("Forbidden".utf8))
        do {
            _ = try await client.todosApply(change, source: .ios)
            XCTFail("a refusal must throw")
        } catch {
            XCTAssertEqual(TodosFailure.of(error), .signedOut)
        }
        XCTAssertEqual(signedOut.count, 1)
        XCTAssertEqual(renewals.count, 1)
    }

    /// What the queue does with each kind of answer: a gateway hiccup waits, a sign-in page
    /// reached through a redirect is a lost sign-in, never a change applied.
    func testAGatewayErrorWaitsAndASignInPageIsASignOut() async throws {
        let client = try TodosStubProtocol.client()
        let change = TodosChangeRequest(changeId: "c1", summary: nil, ops: [.complete(todo: "T-1")])

        TodosStubProtocol.reply(status: 502, contentType: "text/html", body: Data("<html>Bad gateway</html>".utf8))
        do {
            _ = try await client.todosApply(change, source: .ios)
            XCTFail("a 502 must throw")
        } catch {
            XCTAssertEqual(TodosFailure.of(error), .retry)
        }

        TodosStubProtocol.reply(status: 200, contentType: "text/html", body: Data("<html>Sign in</html>".utf8))
        do {
            _ = try await client.todosApply(change, source: .ios)
            XCTFail("a sign-in page must throw")
        } catch {
            XCTAssertEqual(TodosFailure.of(error), .signedOut)
        }
    }

    /// Every write names the door it came through.
    func testAWriteNamesItsSource() async throws {
        let client = try TodosStubProtocol.client()
        TodosStubProtocol.reply(
            status: 200, contentType: "application/json", body: try TodosWireSamples.data("apply-desk-tick"))
        _ = try await client.todosApply(
            TodosChangeRequest(changeId: "c1", summary: nil, ops: [.complete(todo: "T-1")]), source: .shortcut)
        XCTAssertEqual(TodosStubProtocol.lastRequest?.value(forHTTPHeaderField: "X-Todos-Source"), "shortcut")
        XCTAssertEqual(TodosStubProtocol.lastRequest?.url?.path, "/api/todos/apply")
    }

    /// The person's day turns at their rollover, on their wall clock.
    func testTheDayTurnsAtTheRollover() throws {
        let before = try XCTUnwrap(IsoTimestamp.date(from: "2026-11-26T02:00:00+01:00"))
        let after = try XCTUnwrap(IsoTimestamp.date(from: "2026-11-26T03:45:00+01:00"))
        XCTAssertEqual(TodosOverlay.dayOf(before, timezone: "Europe/Berlin", rollover: "03:30"), "2026-11-25")
        XCTAssertEqual(TodosOverlay.dayOf(after, timezone: "Europe/Berlin", rollover: "03:30"), "2026-11-26")
        XCTAssertNil(TodosOverlay.dayOf(after, timezone: "Nowhere/Else", rollover: "03:30"))
    }
}

final class SignOutCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

/// Answers every request with one configured reply and remembers the last request.
final class TodosStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replyStatus = 200
    nonisolated(unsafe) private static var replyType = "application/json"
    nonisolated(unsafe) private static var replyBody = Data()
    nonisolated(unsafe) private static var _lastRequest: URLRequest?

    static func reply(status: Int, contentType: String, body: Data) {
        lock.withLock {
            replyStatus = status
            replyType = contentType
            replyBody = body
        }
    }

    static var lastRequest: URLRequest? { lock.withLock { _lastRequest } }

    static func client(
        onAuthenticationFailure: (@Sendable (PaiError) -> Void)? = nil,
        renewCredential: (@Sendable (String?) async -> CredentialRenewal)? = nil
    ) throws -> PaiApiClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TodosStubProtocol.self]
        let factory = try PaiRequestFactory(baseURL: "https://todos.example.invalid", deviceName: "test") { "token" }
        return PaiApiClient(
            requestFactory: factory, urlSession: URLSession(configuration: configuration),
            onAuthenticationFailure: onAuthenticationFailure, renewCredential: renewCredential)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, type, body) = Self.lock.withLock {
            Self._lastRequest = request
            return (Self.replyStatus, Self.replyType, Self.replyBody)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
