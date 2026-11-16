import PAIKit
import SwiftUI

/// What the watch-key presentations (the naming alert, the revoke question, the one-time key
/// sheet) read and write. Held by `SettingsScreen` and presented from its `Form`, not from the
/// section: a modifier on a `Section` applies to each of its rows, so a sheet hung there is torn
/// down when the list reloads after creating a key, and the presenters multiply across rows.
@MainActor
@Observable
final class WatchKeysPresenter {
    var store: WatchKeysStore?
    var isNaming = false
    var newName = ""
    var keyToRevoke: WatchKey?
}

/// The keys a Garmin watch signs in with: list, create (the plain key is shown once, copyable)
/// and revoke. A person's own, so a guest has them too. Presentations live in
/// ``SwiftUI/View/watchKeyPresentations(_:)``.
struct WatchKeysSection: View {
    let presenter: WatchKeysPresenter

    var body: some View {
        Section {
            ForEach(presenter.store?.keys ?? []) { key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.name)
                    Text(detail(key))
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                .swipeActions {
                    Button("Revoke", role: .destructive) { presenter.keyToRevoke = key }
                }
                .accessibilityIdentifier("watch-key-\(key.id)")
            }
            Button("New watch key") {
                presenter.newName = ""
                presenter.isNaming = true
            }
            .disabled(presenter.store == nil)
            .accessibilityIdentifier("watch-key-new")
        } header: {
            Text("Watch keys")
                .id(FixtureScrollAnchor.watchKeys.rawValue)
        } footer: {
            Text("A key lets a Garmin watch set and dismiss alarms as you. Paste it into the watch app's settings.")
        }
    }

    private func detail(_ key: WatchKey) -> String {
        let used =
            key.lastUsedAt.flatMap(IsoTimestamp.date(from:))
            .map { "last used \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "never used"
        return "\(key.hint)… · \(used)"
    }
}

extension View {
    /// Loads the keys and presents everything the watch-key rows ask for. Applied once, to the
    /// `Form` that holds the section.
    func watchKeyPresentations(_ presenter: WatchKeysPresenter) -> some View {
        modifier(WatchKeyPresentations(presenter: presenter))
    }
}

private struct WatchKeyPresentations: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @Bindable var presenter: WatchKeysPresenter

    private var isAvailable: Bool { environment.connection?.me.capabilities.canOpenAlarm == true }

    func body(content: Content) -> some View {
        content
            .task(id: isAvailable) {
                guard isAvailable, presenter.store == nil, let client = environment.connection?.apiClient else {
                    return
                }
                let created = WatchKeysStore(api: client)
                presenter.store = created
                await created.load()
            }
            .onChange(of: presenter.store?.errorMessage) { _, message in
                if let message { toasts.show(message, kind: .error) }
            }
            .alert("New watch key", isPresented: $presenter.isNaming) {
                TextField("Name, e.g. fenix 8", text: $presenter.newName)
                Button("Create") { Task { await presenter.store?.create(name: presenter.newName) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Revoke this key?",
                isPresented: Binding(
                    get: { presenter.keyToRevoke != nil }, set: { if !$0 { presenter.keyToRevoke = nil } }),
                presenting: presenter.keyToRevoke
            ) { key in
                Button("Revoke \(key.name)", role: .destructive) { Task { await presenter.store?.revoke(key) } }
            } message: { _ in
                Text("The watch using it stops working until it gets a new key.")
            }
            .sheet(
                item: Binding(
                    get: { presenter.store?.justCreated },
                    set: { if $0 == nil { presenter.store?.acknowledgeCreated() } })
            ) { created in
                CreatedKeySheet(created: created)
            }
    }
}

/// The only place the plain key is ever readable.
private struct CreatedKeySheet: View {
    let created: WatchKeyCreated
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(created.key)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("watch-key-plain")
                    Button(copied ? "Copied" : "Copy key") {
                        UIPasteboard.general.string = created.key
                        copied = true
                    }
                    .accessibilityIdentifier("watch-key-copy")
                } header: {
                    Text(created.name)
                } footer: {
                    Text("This key is shown once. Copy it now; it cannot be read again.")
                }
            }
            .navigationTitle("Watch key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
