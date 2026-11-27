import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The MailVerdict assistant's own sign-in. What a change could silently break: the token going
/// with sends to sessions that are not the assistant, landing in the stored outbox, being kept past
/// its expiry so the screen never asks again, or a sign-in that asks for a refresh token or comes
/// back to the wrong place.
@MainActor
final class MailVerdictAssistantSignInTests: XCTestCase {

    private struct Source: MailVerdictSignInSource {
        func mailVerdictSignIn() async throws -> MailVerdictSignInConfig {
            MailVerdictSignInConfig(
                issuer: "https://login.example.invalid", clientId: "ios-client",
                scope: "openid urn:zitadel:iam:org:project:id:42:aud")
        }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private func signedIn(lifetime: Int, clock: Clock) async throws -> MailVerdictAssistantSignIn {
        let signIn = MailVerdictAssistantSignIn(now: { clock.now })
        let request = try await signIn.begin(source: Source())
        PaiStubURLProtocol.reset()
        PaiStubURLProtocol.stub = PaiStubURLProtocol.Stub(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"access_token":"mv-token","token_type":"Bearer","expires_in":\#(lifetime)}"#.utf8))
        let tokens = OidcTokenClient(
            configuration: request.configuration, urlSession: PaiStubURLProtocol.makeSession())
        let callback = URL(string: "pai://mailverdict/callback?code=c1&state=\(request.state)")!
        await signIn.complete(callback: callback, request: request, tokens: tokens)
        return signIn
    }

    func testTheRequestAsksForNoRefreshTokenAndComesBackToTheAssistantsRedirect() async throws {
        let request = try await MailVerdictAssistantSignIn().begin(source: Source())
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(value("client_id"), "ios-client")
        XCTAssertEqual(value("redirect_uri"), "pai://mailverdict/callback")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertFalse((value("scope") ?? "").split(separator: " ").contains("offline_access"))
        XCTAssertTrue((value("scope") ?? "").contains("project:id:42:aud"))
    }

    func testOnlySendsToTheAssistantCarryTheToken() async throws {
        let signIn = try await signedIn(lifetime: 3600, clock: Clock())
        let kinds: [String: SessionKind] = ["mv": .mailverdict, "plain": .conversation]

        XCTAssertEqual(signIn.token(for: .session(sessionId: "mv"), kindOf: { kinds[$0] }), "mv-token")
        XCTAssertNil(signIn.token(for: .session(sessionId: "plain"), kindOf: { kinds[$0] }))
        XCTAssertNil(signIn.token(for: .session(sessionId: "unknown"), kindOf: { kinds[$0] }))
        XCTAssertEqual(
            signIn.token(
                for: .newSession(agent: nil, sessionType: "mailverdict", workingDir: nil, model: nil, thinking: nil),
                kindOf: { kinds[$0] }),
            "mv-token")
        XCTAssertNil(
            signIn.token(
                for: .newSession(agent: nil, sessionType: "home", workingDir: nil, model: nil, thinking: nil),
                kindOf: { kinds[$0] }))
    }

    func testTheTokenIsGoneAMinuteBeforeItExpires() async throws {
        let clock = Clock()
        let signIn = try await signedIn(lifetime: 180, clock: clock)
        XCTAssertEqual(signIn.currentToken(), "mv-token")

        clock.now = clock.now.addingTimeInterval(121)

        XCTAssertNil(signIn.currentToken())
        XCTAssertFalse(signIn.isSignedIn)
    }

    func testAnAnswerForAnotherAttemptHoldsNoToken() async throws {
        let signIn = MailVerdictAssistantSignIn()
        let request = try await signIn.begin(source: Source())

        await signIn.complete(
            callback: URL(string: "pai://mailverdict/callback?code=c1&state=not-this-one")!, request: request,
            tokens: OidcTokenClient(configuration: request.configuration, urlSession: PaiStubURLProtocol.makeSession()))

        XCTAssertNil(signIn.currentToken())
        XCTAssertNotNil(signIn.errorMessage)
    }

    func testTheTokenTravelsAsTheMailVerdictHeaderAndOnlyWhenGiven() async throws {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "pai-jwt" })
        let api = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        PaiStubURLProtocol.reset()
        PaiStubURLProtocol.stub = PaiStubURLProtocol.Stub(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"session_id":"mv","message_id":1}"#.utf8))

        _ = try await api.postMessage(sessionId: "mv", message: "hi", mailVerdictToken: "mv-token")
        let signedIn = try XCTUnwrap(PaiStubURLProtocol.capturedRequest)
        _ = try await api.postMessage(sessionId: "mv", message: "hi")
        let without = try XCTUnwrap(PaiStubURLProtocol.capturedRequest)

        XCTAssertEqual(signedIn.value(forHTTPHeaderField: "X-MailVerdict-Key"), "mv-token")
        XCTAssertEqual(signedIn.value(forHTTPHeaderField: "Authorization"), "Bearer pai-jwt")
        XCTAssertNil(without.value(forHTTPHeaderField: "X-MailVerdict-Key"))
    }

    func testTheOutboxSendsTheTokenWithTheMessageAndNeverStoresIt() async throws {
        let sender = RecordingSender()
        let storage = OutboxInMemoryStorage()
        let outbox = OutboxStore(api: sender, storage: storage)
        outbox.mailVerdictToken = { target in
            if case .session("mv") = target { return "mv-token-123" }
            return nil
        }

        outbox.enqueue(OutboxEntry(target: .session(sessionId: "mv"), text: "what came from the bank?"))
        outbox.enqueue(OutboxEntry(target: .session(sessionId: "plain"), text: "an ordinary session"))
        let deadline = Date().addingTimeInterval(3)
        while sender.tokens.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }

        XCTAssertEqual(sender.tokens["what came from the bank?"], .some("mv-token-123"))
        XCTAssertEqual(sender.tokens["an ordinary session"], .some(nil))
        let stored = String(decoding: try JSONEncoder().encode(storage.loadEntries()), as: UTF8.self)
        XCTAssertFalse(stored.contains("mv-token-123"))
    }
}

private final class RecordingSender: OutboxSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _tokens: [String: String?] = [:]
    var tokens: [String: String?] {
        lock.lock()
        defer { lock.unlock() }
        return _tokens
    }

    private func record(_ message: String, _ token: String?) {
        lock.lock()
        _tokens[message] = token
        lock.unlock()
    }

    func postMessage(
        sessionId: String?, message: String, clientMessageId: String, files: [PaiFileUpload],
        draftAttachmentIds: [String], supersededUploadIds: [String], sessionType: String?, workingDir: String?,
        agent: String?, model: String?,
        thinking: String?, clientMode: String?, heldTake: HeldTake?, noMemory: Bool?,
        mailVerdictToken: String?
    ) async throws -> PostMessageResponse {
        record(message, mailVerdictToken)
        return PostMessageResponse(sessionId: sessionId ?? "new", messageId: 1)
    }
}
