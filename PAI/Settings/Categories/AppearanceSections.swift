import PAIKit
import SwiftUI

struct AppearanceSections: View {
    let settings: SettingsStore

    @Environment(AppEnvironment.self) private var environment
    @State private var arrangingApps = false

    var body: some View {
        ScopedSection(title: "Look", scope: .thisDevice) {
            Picker("Theme", selection: Binding(get: { settings.theme }, set: { settings.setTheme($0) })) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.rawValue.capitalized).tag(theme)
                }
            }
            .accessibilityIdentifier("theme-picker")
        }
        ScopedSection(
            title: "App order", scope: .synced,
            footer:
                "One order for the Apps list in every top bar, the start screen and sleep mode's screen, the same on every device. The apps above the line are shown directly, the rest under More."
        ) {
            Button {
                arrangingApps = true
            } label: {
                LabeledContent("Arrange apps") {
                    Text(shownDirectly)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-app-order")
            .sheet(isPresented: $arrangingApps) {
                AppOrderSheet(registry: settings.registry)
                    .environment(environment)
            }
            #if DEBUG
                .task { if PaiFixtureLaunch.opensAppOrder() { arrangingApps = true } }
            #endif
        }
    }

    /// The apps shown directly, by name, as the row's summary.
    private var shownDirectly: String {
        let names = environment.arrangeableApps.pinned.map(\.title)
        return names.isEmpty ? "All under More" : names.joined(separator: ", ")
    }
}

/// The person's apps as one list to drag: a line in it divides the apps shown directly from the
/// ones under More. Every move is stored at once; a refused one puts the list back and says why.
struct AppOrderSheet: View {
    let registry: SettingsRegistryStore

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// What is on screen, top to bottom: app ids with the line among them.
    private var sequence: [String] {
        let apps = environment.arrangeableApps
        return apps.pinned.map(\.id) + [AppOrder.line] + apps.more.map(\.id)
    }

    var body: some View {
        let rows = sequence
        NavigationStack {
            List {
                Section {
                    ForEach(rows, id: \.self) { id in
                        row(id)
                    }
                    .onMove { from, to in move(rows, from, to) }
                } header: {
                    Text("Shown directly")
                } footer: {
                    footer
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("App order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("app-order-sheet")
        .fixtureFact("appOrder", rows.joined(separator: ","))
    }

    @ViewBuilder
    private func row(_ id: String) -> some View {
        if id == AppOrder.line {
            Label("Under More, below this line", systemImage: "arrow.down.to.line")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .listRowBackground(PaiPalette.Semantic.accentBackground)
                .accessibilityIdentifier("app-order-line")
        } else if let entry = AppRegistry.all.first(where: { $0.id == id }) {
            Label(entry.title, systemImage: entry.systemImage)
                .accessibilityIdentifier("app-order-\(id)")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error = registry.errorMessage {
            Text(error).foregroundStyle(PaiPalette.Semantic.errorText)
        } else {
            Text(
                "Drag an app above or below the line. Apps that cannot be opened during sleep mode are left out of its screen."
            )
        }
    }

    private func move(_ rows: [String], _ from: IndexSet, _ to: Int) {
        var next = rows
        next.move(fromOffsets: from, toOffset: to)
        Task { await registry.setAppOrder(sequence: next) }
    }
}
