import PAIKit
import SwiftUI

/// Where the top bar's "Apps" button leads — a small picker over every app in `AppRegistry`, each
/// shown to those whose capabilities admit it, and while sleep mode is on only the ones it leaves.
/// Mirrors the web's own `AppsFlyout`/`AppsHome` pairing (a modal listing every registered app),
/// minus Memory and Notifications: PAI Cloud's Memory app is notes plus projects/phases/search,
/// and this repo never built a separate Memory screen — the note index (`.notes`) is the one
/// entry point this app already has for it, so it is what "memory, reachable under Apps" means
/// here. Notifications keeps its own always-visible top bar icon: unlike the
/// three apps here, it carries a live unread badge that would otherwise be hidden a tap deeper.
struct AppsHomeSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private var capabilities: Capabilities { environment.connection?.me.capabilities ?? .unknown }

    var body: some View {
        NavigationStack {
            List {
                // Drawn from the registry, which also decides who may open each row: a guest's
                // request for an owner-only one would be refused. Quick Actions is first, because it
                // is the only entry that is also a whole screen of its own shortcuts: the hardware
                // Action Button is its other door, and a phone without that button has no other way in.
                ForEach(AppRegistry.visible(for: capabilities, asleep: environment.router.isAsleep)) { entry in
                    Button {
                        open(entry)
                    } label: {
                        row(entry)
                    }
                    .accessibilityIdentifier("apps-open-\(entry.id)")
                }
            }
            .listStyle(.plain)
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("apps-sheet")
    }

    @ViewBuilder
    private func row(_ entry: AppEntry) -> some View {
        if entry.id == AppRegistry.decisionsID {
            Label {
                HStack {
                    Text(entry.title)
                    Spacer()
                    if let count = environment.connection?.decisions.open.count, count > 0 {
                        Text("\(count)").foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
            } icon: {
                Image(systemName: entry.systemImage)
            }
        } else {
            Label(entry.title, systemImage: entry.systemImage)
        }
    }

    // Push before dismissing — the same order `CreateSessionView` uses and documents on itself: a
    // push onto the stack behind a sheet that is mid-dismissal is dropped often enough to be a known
    // iOS trap, and the failure is silent. Reversing the order would leave the user looking at the
    // session list with the Apps sheet merely closed, having to tap the destination a second time.
    private func open(_ entry: AppEntry) {
        // Todos opens where it was left.
        environment.router.push(entry.route == .todos ? TodosEntry.route(environment) : entry.route)
        dismiss()
    }
}
