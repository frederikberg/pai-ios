import AuthenticationServices
import PAIKit
import SwiftUI

/// Above the composer of a MailVerdict assistant session: whether the app is signed in to
/// MailVerdict, and the one tap that signs it in. Without it the assistant cannot reach mail.
/// The sign-in lasts while the app runs and ends with its access token; nothing stores it.
struct MailVerdictSignInBar: View {
    let signIn: MailVerdictAssistantSignIn
    let api: PaiApiClient

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(caption)
                        .font(.footnote)
                    if let error = signIn.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }
                Spacer(minLength: 8)
                if signIn.isSignedIn {
                    Button("Sign out") { signIn.forget() }
                        .font(.footnote)
                } else {
                    Button(signIn.signingIn ? "Signing in…" : "Sign in") {
                        Task { await start() }
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(signIn.signingIn)
                    .accessibilityIdentifier("mailverdict-sign-in")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var caption: String {
        guard signIn.isSignedIn, let expiresAt = signIn.expiresAt else {
            return "The assistant reaches your mail only after you sign in to MailVerdict."
        }
        let until = expiresAt.addingTimeInterval(-MailVerdictAssistantSignIn.expiryMargin)
        return "Signed in to MailVerdict until \(until.formatted(date: .omitted, time: .shortened))."
    }

    /// Zitadel's login in the shared browser session (a login already made there is reused, so
    /// this is usually one tap), back through the `pai://mailverdict` callback.
    private func start() async {
        do {
            let request = try await signIn.begin(source: api)
            let callback = try await webAuthenticationSession.authenticate(
                using: request.url,
                callbackURLScheme: request.configuration.callbackScheme,
                preferredBrowserSession: .shared
            )
            await signIn.complete(callback: callback, request: request)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            signIn.cancel()
        } catch {
            signIn.cancel(error: error)
        }
    }
}
