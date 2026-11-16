import PAIKit
import SwiftUI

/// The keys a Garmin watch signs in with: list, create (the plain key is shown once, copyable)
/// and revoke. A person's own, so a guest has them too.
struct WatchKeysSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @State private var store: WatchKeysStore?
    @State private var isNaming = false
    @State private var newName = ""
    @State private var keyToRevoke: WatchKey?

    var body: some View {
        Section {
            ForEach(store?.keys ?? []) { key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.name)
                    Text(detail(key))
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                .swipeActions {
                    Button("Revoke", role: .destructive) { keyToRevoke = key }
                }
                .accessibilityIdentifier("watch-key-\(key.id)")
            }
            Button("New watch key") {
                newName = ""
                isNaming = true
            }
            .disabled(store == nil)
            .accessibilityIdentifier("watch-key-new")
        } header: {
            Text("Watch keys")
        } footer: {
            Text("A key lets a Garmin watch set and dismiss alarms as you. Paste it into the watch app's settings.")
        }
        .id(FixtureScrollAnchor.watchKeys.rawValue)
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let created = WatchKeysStore(api: client)
            store = created
            await created.load()
        }
        .onChange(of: store?.errorMessage) { _, message in
            if let message { toasts.show(message, kind: .error) }
        }
        .alert("New watch key", isPresented: $isNaming) {
            TextField("Name, e.g. fenix 8", text: $newName)
            Button("Create") { Task { await store?.create(name: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Revoke this key?",
            isPresented: Binding(get: { keyToRevoke != nil }, set: { if !$0 { keyToRevoke = nil } }),
            presenting: keyToRevoke
        ) { key in
            Button("Revoke \(key.name)", role: .destructive) { Task { await store?.revoke(key) } }
        } message: { _ in
            Text("The watch using it stops working until it gets a new key.")
        }
        .sheet(
            item: Binding(
                get: { store?.justCreated }, set: { if $0 == nil { store?.acknowledgeCreated() } })
        ) { created in
            CreatedKeySheet(created: created)
        }
    }

    private func detail(_ key: WatchKey) -> String {
        let used =
            key.lastUsedAt.flatMap(IsoTimestamp.date(from:))
            .map { "last used \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "never used"
        return "\(key.hint)… · \(used)"
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
