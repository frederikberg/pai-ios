import PAIKit
import SwiftUI

/// The phones and browsers signed in as the person, each with a way to sign it out, and the keys
/// a watch reaches their alarms with. Only the person's own: everyone's is an administration page.
struct DevicesSections: View {
    let presenter: WatchKeysPresenter
    let signIns: SignInsStore

    var body: some View {
        SignInListSections(store: signIns, showsPerson: false)
        // Watch keys: a person's own, so a guest has them too.
        WatchKeysSection(presenter: presenter)
    }
}

/// A list of signed-in devices, grouped by person for the owner's administration view, with
/// sign-out per device and for a whole person. The caller's own phone has no Sign out here: the
/// Sign out button on the Settings list ends it properly, on the backend too.
struct SignInListSections: View {
    let store: SignInsStore
    let showsPerson: Bool

    @State private var confirming: SignInGroup?

    var body: some View {
        Group {
            if store.rows == nil {
                Section {
                    if let error = store.errorMessage {
                        Text(error)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    } else {
                        ProgressView()
                    }
                }
            } else {
                ForEach(store.groups) { group in
                    Section {
                        ForEach(group.signIns) { signIn in
                            row(signIn)
                        }
                        if group.hasActive {
                            // The dialog hangs on its one button, not on the section: a presentation
                            // on a container is applied to every row it holds.
                            Button("Sign out everywhere", role: .destructive) { confirming = group }
                                .accessibilityIdentifier("sign-out-everywhere-\(group.id)")
                                .confirmationDialog(
                                    "Sign out everywhere?", isPresented: confirmingBinding(group),
                                    titleVisibility: .visible
                                ) {
                                    Button("Sign out everywhere", role: .destructive) {
                                        Task { await store.signOutEverywhere(of: group) }
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text(
                                        "Every phone and browser of this person is signed out, this one included if it is theirs."
                                    )
                                }
                        }
                    } header: {
                        Text(showsPerson ? (group.displayName ?? "Unknown person") : "Signed in")
                    }
                }
                if let error = store.errorMessage, store.rows != nil {
                    Section {
                        Text(error)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }
            }
        }
    }

    private func row(_ signIn: SignIn) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(SignInLabel.title(signIn) + (signIn.current == true ? " (this iPhone)" : ""))
                Text(SignInLabel.detail(signIn))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            Spacer(minLength: 0)
            if signIn.active, signIn.current != true {
                Button("Sign out") { Task { await store.revoke(signIn) } }
                    .buttonStyle(.borderless)
                    .disabled(store.isBusy)
            }
        }
        .accessibilityIdentifier("sign-in-\(signIn.id)")
    }

    private func confirmingBinding(_ group: SignInGroup) -> Binding<Bool> {
        Binding(get: { confirming?.id == group.id }, set: { if !$0 { confirming = nil } })
    }
}

/// What a sign-in is called in a list and what its second line says.
enum SignInLabel {
    static func title(_ signIn: SignIn) -> String {
        if signIn.kind == .browser { return "Web browsers" }
        if let name = signIn.name, !name.isEmpty { return name }
        if let client = signIn.clientId, !client.isEmpty { return client }
        return signIn.kind == .machine ? "Machine" : "Phone app"
    }

    static func detail(_ signIn: SignIn) -> String {
        if !signIn.active {
            let when = signIn.revokedAt.flatMap(IsoTimestamp.date(from:)).map(format) ?? ""
            return "Signed out \(when)".trimmingCharacters(in: .whitespaces)
        }
        let seen =
            signIn.lastSeenAt.flatMap(IsoTimestamp.date(from:)).map { "Last used \(format($0))" } ?? "Not used yet"
        if signIn.kind == .browser, let agent = signIn.userAgent, !agent.isEmpty { return "\(seen) · \(agent)" }
        return seen
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
