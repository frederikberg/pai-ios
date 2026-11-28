import PAIKit
import SwiftUI

/// The Apps list, opened from the Apps button in any top bar: the apps in the person's order, the
/// ones they chose to see directly first and the rest under "More", each shown to those whose
/// capabilities admit it, and while sleep mode is on only the ones it leaves. Picking one goes to
/// it on the screens it was left on.
///
/// Notifications keeps its own top bar icon on the session list: it carries a live unread badge
/// that would otherwise be hidden a tap deeper.
struct AppsHomeSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let apps = environment.arrangedApps
        NavigationStack {
            List {
                Section {
                    ForEach(apps.pinned) { entry in button(entry) }
                }
                if !apps.more.isEmpty {
                    Section(apps.pinned.isEmpty ? "" : "More") {
                        ForEach(apps.more) { entry in button(entry) }
                    }
                }
                if !environment.router.isAsleep {
                    Section {
                        Button {
                            environment.router.replace(with: [.apps])
                            dismiss()
                        } label: {
                            Label("Start screen", systemImage: "square.grid.2x2")
                        }
                        .accessibilityIdentifier("apps-open-start")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("apps-sheet")
        .fixtureFact("appsSheetPinned", apps.pinned.map(\.id).joined(separator: ","))
    }

    private func button(_ entry: AppEntry) -> some View {
        Button {
            open(entry)
        } label: {
            row(entry)
        }
        .accessibilityIdentifier("apps-open-\(entry.id)")
    }

    private func row(_ entry: AppEntry) -> some View {
        Label {
            HStack {
                Text(entry.title)
                Spacer()
                Text(detail(entry)).foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        } icon: {
            Image(systemName: entry.systemImage)
        }
        .contentShape(Rectangle())
    }

    /// What stands at the end of a row: where the person is, or how many decisions wait.
    private func detail(_ entry: AppEntry) -> String {
        if entry.id == environment.currentAppID { return "You are here" }
        if entry.id == AppRegistry.decisionsID, let count = environment.connection?.decisions.open.count, count > 0 {
            return "\(count) open"
        }
        return ""
    }

    // The path changes before the sheet leaves: a navigation asked for from behind a dismissing
    // sheet is dropped silently.
    private func open(_ entry: AppEntry) {
        environment.open(entry)
        dismiss()
    }
}
