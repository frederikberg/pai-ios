import PAIKit
import SwiftUI

/// The Actions Library: every Action and Shortcut there is, in three sections by where it sits.
/// Grid and More are reordered by dragging; each row's menu moves it to the grid, into More or
/// out of sight; a shortcut is added from the toolbar and deleted like a row in any list.
///
/// A `List` held in edit mode rather than a draggable grid: its drag handles, reordering and
/// delete controls are the system's own and behave the same in every section, where drag and drop
/// between grid cells would have to be built and tuned by hand.
struct QuickActionsLibrarySheet: View {
    let store: QuickActionsStore
    let capabilities: Capabilities

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @State private var editingShortcut: QuickActionShortcut?
    @State private var addingShortcut = false
    @State private var addingTodosPage = false
    @State private var confirmingReset = false

    private var librarySummary: String {
        QuickActionPlacement.allCases.map { placement in
            let names = store.items(in: placement).map(\.summaryName).joined(separator: ",")
            return "\(placement.rawValue):\(names)"
        }.joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            List {
                section(.grid, footer: "Five rows of three fit on the screen; the rest scrolls.")
                section(.more, footer: "Opened by the More tile, which shows while More holds something.")
                section(.hidden, footer: nil)
                Section {
                    Button("Restore the standard layout", role: .destructive) { confirmingReset = true }
                        .accessibilityIdentifier("quick-library-reset")
                        .id(FixtureScrollAnchor.quickLibraryEnd.rawValue)
                }
            }
            .environment(\.editMode, .constant(.active))
            .fixtureScrollsToAnchor()
            .navigationTitle("Actions Library")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("quick-library")
            .fixtureFact("quickActionsLibrary", librarySummary)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Add Shortcut", systemImage: "arrow.up.forward.app") { addingShortcut = true }
                        if capabilities.canOpenTodos {
                            Button("Add a Todos view or list", systemImage: "checklist") { addingTodosPage = true }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityIdentifier("quick-library-add")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Restore the standard layout?", isPresented: $confirmingReset, titleVisibility: .visible
            ) {
                Button("Restore", role: .destructive) { store.resetToStandard() }
            } message: {
                Text("Your shortcuts are kept, hidden.")
            }
            .sheet(item: $editingShortcut) { shortcut in
                ShortcutEditSheet(
                    shortcut: shortcut,
                    onSave: { store.updateShortcut($0) },
                    onDelete: { store.deleteShortcut(shortcut.id) })
            }
            .sheet(isPresented: $addingTodosPage) {
                TodosPagePickerSheet(browse: todosBrowse) { store.addTodosPage($0) }
            }
            .sheet(isPresented: $addingShortcut) {
                ShortcutEditSheet(
                    shortcut: nil, onSave: { _ = store.addShortcut(name: $0.name, urlString: $0.urlString) })
            }
            #if DEBUG
                .task {
                    if PaiFixtureLaunch.isEnabled(), PaiFixtureLaunch.requestedQuickEdit() == "addShortcut" {
                        addingShortcut = true
                    }
                }
            #endif
        }
    }

    private func section(_ placement: QuickActionPlacement, footer: String?) -> some View {
        let items = store.items(in: placement)
        return Section {
            if items.isEmpty {
                Text("Nothing here")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            ForEach(items, id: \.self) { item in
                row(item)
                    .deleteDisabled(!isShortcut(item))
                    .moveDisabled(placement == .hidden)
            }
            .onMove { source, destination in
                store.move(in: placement, fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                for offset in offsets {
                    switch items[offset] {
                    case .shortcut(let id): store.deleteShortcut(id)
                    case .todosPage(let key): store.deleteTodosPage(key)
                    case .action, .more: break
                    }
                }
            }
        } header: {
            Text("\(placement.title) · \(items.count)")
        } footer: {
            if let footer { Text(footer) }
        }
    }

    /// Shortcuts and Todos page tiles are the person's own and can be deleted; built-in actions only hidden.
    private func isShortcut(_ item: QuickActionItem) -> Bool {
        switch item {
        case .shortcut, .todosPage: true
        case .action, .more: false
        }
    }

    private var todosBrowse: TodoBrowse {
        TodoBrowse.make(me: environment.todos.me, viewCounts: [:])
    }

    @ViewBuilder
    private func row(_ item: QuickActionItem) -> some View {
        switch item {
        case .action(let action):
            let available = action.isAvailable(to: capabilities)
            rowLabel(
                title: action.title, subtitle: available ? action.subtitle : "Not on this account",
                systemImage: action.systemImage, item: item
            )
            .opacity(available ? 1 : 0.45)
        case .shortcut(let id):
            if let shortcut = store.shortcut(id) {
                rowLabel(
                    title: shortcut.title, subtitle: shortcut.subtitle, systemImage: "arrow.up.forward.app", item: item)
            }
        case .todosPage(let key):
            rowLabel(
                title: TodoPage(key: key).flatMap { todosBrowse.entry(for: $0)?.title } ?? "Todos view",
                subtitle: "Opens this Todos page", systemImage: "checklist", item: item)
        case .more:
            rowLabel(
                title: "More", subtitle: "The tile that opens More", systemImage: "ellipsis.circle.fill", item: item)
        }
    }

    private func rowLabel(title: String, subtitle: String, systemImage: String, item: QuickActionItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                Text(subtitle)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            Spacer(minLength: 8)
            if case .shortcut(let id) = item, let shortcut = store.shortcut(id) {
                Button("Edit", systemImage: "pencil") { editingShortcut = shortcut }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("quick-library-edit-\(shortcut.title)")
            }
            if item != .more {
                placementPicker(item)
            }
        }
        .accessibilityIdentifier("quick-library-row-\(item.summaryName)")
    }

    private func placementPicker(_ item: QuickActionItem) -> some View {
        Picker(
            "Place",
            selection: Binding(
                get: { store.placement(of: item) },
                set: { store.place(item, in: $0) })
        ) {
            ForEach(QuickActionPlacement.allCases, id: \.self) { placement in
                Text(placement.title).tag(placement)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// The name and link of a shortcut, new or existing. Nothing is saved until Save, and Save waits
/// for a link that parses.
struct ShortcutEditSheet: View {
    let shortcut: QuickActionShortcut?
    let onSave: (QuickActionShortcut) -> Void
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var urlString: String

    init(
        shortcut: QuickActionShortcut?, onSave: @escaping (QuickActionShortcut) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.shortcut = shortcut
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: shortcut?.name ?? "")
        _urlString = State(initialValue: shortcut?.urlString ?? "")
    }

    private var draft: QuickActionShortcut {
        var draft = shortcut ?? QuickActionShortcut(name: "", urlString: "")
        draft.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("shortcut-edit-name")
                    TextField("Link", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("shortcut-edit-url")
                } footer: {
                    Text(
                        "A link another app opens, or any web address."
                    )
                }
                if let onDelete {
                    Section {
                        Button("Delete Shortcut", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                        .accessibilityIdentifier("shortcut-edit-delete")
                    }
                }
            }
            .navigationTitle(shortcut == nil ? "New Shortcut" : "Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("shortcut-edit-sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.url == nil)
                    .accessibilityIdentifier("shortcut-edit-save")
                }
            }
        }
    }
}

/// Picks the Todos view or list a new tile opens.
struct TodosPagePickerSheet: View {
    let browse: TodoBrowse
    let onPick: (TodoPage) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                section("Views", browse.favourites + browse.moreViews)
                section("Lists", browse.lists)
            }
            .navigationTitle("Todos view or list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func section(_ title: String, _ entries: [TodoBrowse.Entry]) -> some View {
        Section(title) {
            ForEach(entries) { entry in
                Button {
                    if let page = entry.page { onPick(page) }
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        TodoIdentityIcon(identity: entry.identity)
                        Text(entry.title).foregroundStyle(PaiPalette.Semantic.textStrong)
                    }
                }
            }
        }
    }
}
