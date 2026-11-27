import Foundation
import Observation

/// What the sign-in needs of the backend, narrowed so a test fakes it without a stub server.
public protocol MailVerdictSignInSource: Sendable {
    func mailVerdictSignIn() async throws -> MailVerdictSignInConfig
}

extension PaiApiClient: MailVerdictSignInSource {}

/// The MailVerdict assistant's own sign-in to MailVerdict, for as long as the app runs.
///
/// PAI's sign-in does not reach MailVerdict. The assistant's screen starts an authorization-code
/// flow with PKCE (``begin(source:)``) with the public client and the scope the backend names,
/// the app shows it in a web authentication session, and ``complete(callback:request:tokens:)``
/// trades the code for an access token. No refresh token is asked for. The token is held here in
/// memory only — never in the Keychain, the outbox or the defaults — and goes out as
/// `X-MailVerdict-Key` with each message to a MailVerdict assistant session
/// (``token(for:kindOf:)``). A minute before it expires it is treated as gone, so the screen asks
/// again.
@MainActor
@Observable
public final class MailVerdictAssistantSignIn {
    /// Where the web authentication session comes back to; registered as the client's redirect.
    nonisolated public static let redirectURI = URL(string: "pai://mailverdict/callback")!
    /// A token this close to its expiry is treated as gone.
    nonisolated public static let expiryMargin: TimeInterval = 60

    public private(set) var expiresAt: Date?
    public private(set) var signingIn = false
    public private(set) var errorMessage: String?
    private var accessToken: String?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Whether a usable token is held at this moment.
    public var isSignedIn: Bool { currentToken() != nil }

    /// The held token, or `nil` without one or within ``expiryMargin`` of its expiry.
    public func currentToken() -> String? {
        guard let accessToken, let expiresAt, expiresAt.timeIntervalSince(now()) > Self.expiryMargin else {
            return nil
        }
        return accessToken
    }

    /// The token a send to `target` carries: only a send to a MailVerdict assistant session gets
    /// one. `kindOf` answers an existing session's kind.
    public func token(for target: OutboxTarget, kindOf: (String) -> SessionKind?) -> String? {
        switch target {
        case .newSession(_, let sessionType, _, _, _):
            guard sessionType == CreateSessionStore.mailverdictSessionTypeId else { return nil }
        case .session(let sessionId):
            guard kindOf(sessionId) == .mailverdict else { return nil }
        }
        return currentToken()
    }

    /// The authorization request for this attempt; the caller opens its ``OidcAuthorizationRequest/url``.
    public func begin(source: any MailVerdictSignInSource) async throws -> OidcAuthorizationRequest {
        signingIn = true
        errorMessage = nil
        do {
            let config = try await source.mailVerdictSignIn()
            guard let issuer = URL(string: config.issuer) else { throw OidcError.unavailable("unreadable issuer") }
            let configuration = OidcConfiguration(
                issuer: issuer, clientId: config.clientId, redirectURI: Self.redirectURI,
                scopes: config.scope.split(separator: " ").map(String.init))
            return OidcAuthorizationRequest(configuration: configuration)
        } catch {
            fail(error)
            throw error
        }
    }

    /// Takes the redirect the web authentication session returned and holds the token it buys.
    /// `tokens` is the token endpoint client; a test passes one over a stub session.
    public func complete(
        callback: URL, request: OidcAuthorizationRequest, tokens: OidcTokenClient? = nil
    ) async {
        defer { signingIn = false }
        do {
            let code = try request.authorizationCode(from: callback)
            let client = tokens ?? OidcTokenClient(configuration: request.configuration)
            let set = try await client.exchange(code: code, for: request)
            guard let lifetime = set.expiresIn else { throw OidcError.unavailable("the token came without a lifetime") }
            accessToken = set.accessToken
            expiresAt = now().addingTimeInterval(lifetime)
        } catch {
            fail(error)
        }
    }

    /// The attempt ended without a token (closed by the person, or failed before the callback).
    public func cancel(error: Error? = nil) {
        signingIn = false
        if let error { fail(error) }
    }

    /// Forget the token; the next message asks again.
    public func forget() {
        accessToken = nil
        expiresAt = nil
        errorMessage = nil
    }

    private func fail(_ error: Error) {
        signingIn = false
        errorMessage = (error as? OidcError)?.userMessage ?? "MailVerdict sign-in failed: \(error.localizedDescription)"
    }
}
