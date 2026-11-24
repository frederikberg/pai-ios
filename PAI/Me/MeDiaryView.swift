import PAIKit
import SwiftUI

/// The person's own words, newest first, grouped by Berlin day. A day without entries does not
/// exist here: no gap marker, no count.
struct MeDiaryView: View {
    let write: () -> Void
    let edit: (SelfReport) -> Void
    @Environment(SelfReportStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private let presenter = MePresenter()
    private var dark: Bool { scheme == .dark }

    private var visible: [MeDiaryItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.items }
        return store.items.filter { ($0.report.text ?? "").lowercased().contains(needle) }
    }

    var body: some View {
        let items = visible
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = presenter.groups(of: items.map(\.report), todayKey: presenter.dayKey(Date()))
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    filters
                    if searching { searchField }
                    if groups.isEmpty && !store.isLoading {
                        Text(
                            "Nothing here yet. Write when you feel like it — a face, a sentence, a whole evening. Nobody counts."
                        )
                        .font(PaiTypography.body.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .padding(.top, 24)
                        .accessibilityIdentifier("me-diary-empty")
                    }
                    ForEach(groups) { group in
                        HStack {
                            Text(group.title).font(PaiTypography.panelTitle.font)
                                .foregroundStyle(PaiPalette.Semantic.textStrong)
                            Spacer()
                            Text(group.dateLabel).font(PaiTypography.body.font)
                                .foregroundStyle(PaiPalette.Semantic.textMuted)
                        }
                        .padding(.top, 14)
                        ForEach(group.entries) { entry in
                            if let item = byId[entry.id] { row(item) }
                        }
                    }
                    if store.hasMore, query.isEmpty {
                        Color.clear.frame(height: 1).onAppear { Task { await store.loadMore() } }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            }
            .refreshable { await store.reload() }
            Button(action: write) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(PaiPalette.primary500, in: Circle())
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(20)
            .accessibilityLabel("Write an entry")
            .accessibilityIdentifier("me-diary-write")
        }
        .task { await store.loadIfNeeded() }
        .onChange(of: store.feelFilter) { _, _ in Task { await store.reload() } }
        .onChange(of: store.privateOnly) { _, _ in Task { await store.reload() } }
        .fixtureFact("meDiaryRows", "\(items.count)")
    }

    // MARK: Filters

    private var filters: some View {
        HStack(spacing: 8) {
            chip(selected: store.feelFilter == nil && !store.privateOnly, id: "all") {
                Text("All").font(PaiTypography.bodyEmphasized.font)
            } action: {
                store.feelFilter = nil
                store.privateOnly = false
            }
            ForEach([SelfReportFeel.good, .okay, .heavy], id: \.wire) { feel in
                chip(selected: store.feelFilter == feel, id: "feel-\(feel.wire ?? "")") {
                    FeelFace(feel: feel, size: 20)
                } action: {
                    store.feelFilter = store.feelFilter == feel ? nil : feel
                }
                .accessibilityLabel("\(feel.spokenName) entries")
            }
            chip(selected: store.privateOnly, id: "private") {
                Label("Private", systemImage: "lock")
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(MeColor.lock(dark: dark))
            } action: {
                store.privateOnly.toggle()
            }
            Spacer(minLength: 0)
            Button {
                searching.toggle()
                if searching { searchFocused = true } else { query = "" }
            } label: {
                Image(systemName: "magnifyingglass").foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            .accessibilityLabel("Search the diary")
            .accessibilityIdentifier("me-diary-search")
        }
        .padding(.vertical, 4)
    }

    private func chip<Label: View>(
        selected: Bool, id: String, @ViewBuilder label: () -> Label, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .background(selected ? PaiPalette.Semantic.insetBackground : .clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? .clear : PaiPalette.Semantic.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("me-diary-filter-\(id)")
    }

    private var searchField: some View {
        TextField("Search the loaded entries", text: $query)
            .focused($searchFocused)
            .padding(10)
            .background(PaiPalette.Semantic.insetBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Rows

    private func row(_ item: MeDiaryItem) -> some View {
        MeEntryCard(item: item, presenter: presenter)
            .contextMenu {
                if item.refusal != nil {
                    Button("Put back in composer", systemImage: "arrow.uturn.backward") {
                        store.putBack(id: item.id)
                        write()
                    }
                } else if !item.waiting {
                    Button("Edit", systemImage: "pencil") { edit(item.report) }
                    Button(
                        item.report.isPrivate ? "Make visible" : "Make private",
                        systemImage: item.report.isPrivate ? "lock.open" : "lock"
                    ) {
                        Task { await store.setPrivate(id: item.id, !item.report.isPrivate) }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(item.report) }
                }
            }
    }

    private func delete(_ report: SelfReport) {
        Task {
            guard await store.delete(report) else {
                toasts.show(store.errorMessage ?? "Could not delete", kind: .error)
                return
            }
            toasts.show(
                "Entry deleted", kind: .info,
                action: ToastMessage.Action(label: "Undo") { Task { await store.restore(report) } },
                lifetimeNanos: 6_000_000_000)
        }
    }
}
