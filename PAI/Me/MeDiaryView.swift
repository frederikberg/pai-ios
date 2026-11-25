import PAIKit
import SwiftUI

/// The person's own words, newest first, grouped by Berlin day. A day without entries does not
/// exist here: no gap marker, no count.
struct MeDiaryView: View {
    /// The 14-day window the grid shows; its entries are what the chips count.
    let overview: MeOverviewStore
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
                    countsCaption
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
                Text(counted("All", counts?.all)).font(PaiTypography.bodyEmphasized.font)
            } action: {
                store.feelFilter = nil
                store.privateOnly = false
            }
            ForEach([SelfReportFeel.good, .okay, .heavy], id: \.wire) { feel in
                chip(selected: store.feelFilter == feel, id: "feel-\(feel.wire ?? "")") {
                    HStack(spacing: 5) {
                        FeelFace(feel: feel, size: 20)
                        if let count = count(of: feel) { Text("\(count)").font(PaiTypography.bodyEmphasized.font) }
                    }
                } action: {
                    store.feelFilter = store.feelFilter == feel ? nil : feel
                }
                .accessibilityLabel("\(feel.spokenName) entries")
            }
            chip(selected: store.privateOnly, id: "private") {
                HStack(spacing: 4) {
                    Image(systemName: "lock")
                    if let locked = counts?.locked, locked > 0 { Text("\(locked)") }
                }
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(MeColor.lock(dark: dark))
            } action: {
                store.privateOnly.toggle()
            }
            .accessibilityLabel("Private entries")
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

    /// How many entries the 14 days on screen hold, by face; nil until the overview has loaded.
    private var counts: MeDiaryCounts? {
        overview.overview.map { presenter.diaryCounts(days: $0.days) }
    }

    private func count(of feel: SelfReportFeel) -> Int? {
        guard let counts else { return nil }
        let count: Int
        switch feel {
        case .good: count = counts.good
        case .okay: count = counts.okay
        case .heavy: count = counts.heavy
        case .unrecognized: return nil
        }
        return count > 0 ? count : nil
    }

    private func counted(_ title: String, _ count: Int?) -> String {
        guard let count, count > 0 else { return title }
        return "\(title) \(count)"
    }

    /// The counts are the grid's days, not everything below: say so beside them.
    @ViewBuilder
    private var countsCaption: some View {
        if let loaded = overview.overview, let first = loaded.days.first?.date, let last = loaded.days.last?.date {
            Text("counts for \(presenter.rangeTitle(from: first, to: last))")
                .font(.system(size: 11))
                .foregroundStyle(PaiPalette.Semantic.textFaint)
                .accessibilityIdentifier("me-diary-counts-range")
        }
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
        MeEntryRow(item: item, presenter: presenter)
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
