import PAIKit
import SwiftUI

/// One of the three shortcuts in the More list — a link the user configures through the row's
/// context menu, or by tapping an unconfigured one, since Todoist's own view/filter URLs are theirs to find and paste rather than something
/// this app can construct (a saved-filter URL in particular names an id only their account has).
/// Persisted locally, never synced: this is a per-device convenience, not app state PAI Cloud
/// needs to know about.
private struct QuickActionShortcut: Equatable {
    var name: String
    var urlString: String

    var isConfigured: Bool { !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var url: URL? { isConfigured ? URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
}

/// Where the hardware Action Button lands: a three-column grid whose placement is
/// ``QuickActionLayout``. Self-report, Me and the More tile on top, then the typed and call
/// shortcuts, with the actions the grid has no room for behind the More tile as a scrollable list.
///
/// The button is pressed without looking — walking, in a coat pocket, mid-sentence — so the whole
/// screen is one glance and one thumb. That is what sets the shape: large targets rather than a
/// list, each laid out so a tile's position is learnable and stays put. Nothing here loads, so
/// there is no state in which the grid is not yet tappable.
///
/// 🚨 Row height is divided out of the measured screen by `rowCount`, then held between a floor
/// and a ceiling. The floor keeps a target big enough to hit without looking on a small phone;
/// the ceiling keeps a large one from stretching every tile to fill space it does not need, which
/// reads as a screen of enormous buttons rather than a glanceable grid.
struct QuickActionsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NotesStore.self) private var notes
    @Environment(DraftStore.self) private var drafts
    @Environment(ToastCenter.self) private var toasts
    @Environment(SelfReportStore.self) private var selfReports

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16
    private var rowCount: CGFloat { CGFloat(QuickActionLayout.grid.count) }
    /// Big enough to hit without looking, on the smallest phone this runs on.
    private let minRowHeight: CGFloat = 88
    private let maxRowHeight: CGFloat = 120

    @AppStorage("quickActionShortcut1Name") private var shortcut1Name = ""
    @AppStorage("quickActionShortcut1URL") private var shortcut1URLString = ""
    @AppStorage("quickActionShortcut2Name") private var shortcut2Name = ""
    @AppStorage("quickActionShortcut2URL") private var shortcut2URLString = ""
    @AppStorage("quickActionShortcut3Name") private var shortcut3Name = ""
    @AppStorage("quickActionShortcut3URL") private var shortcut3URLString = ""
    @State private var editingShortcutSlot: Int?
    @State private var writingEntry = false
    @State private var showingMore = false
    /// What a tap in the More list asked for. It runs once the list has finished leaving: an
    /// action that presents or navigates from behind a dismissing sheet is dropped silently.
    @State private var afterMore: (() -> Void)?

    private func shortcut(slot: Int) -> QuickActionShortcut {
        switch slot {
        case 1: QuickActionShortcut(name: shortcut1Name, urlString: shortcut1URLString)
        case 2: QuickActionShortcut(name: shortcut2Name, urlString: shortcut2URLString)
        default: QuickActionShortcut(name: shortcut3Name, urlString: shortcut3URLString)
        }
    }

    private func shortcutNameBinding(slot: Int) -> Binding<String> {
        switch slot {
        case 1: $shortcut1Name
        case 2: $shortcut2Name
        default: $shortcut3Name
        }
    }

    private func shortcutURLBinding(slot: Int) -> Binding<String> {
        switch slot {
        case 1: $shortcut1URLString
        case 2: $shortcut2URLString
        default: $shortcut3URLString
        }
    }

    var body: some View {
        // Measured rather than given a fixed tile height: the whole point is targets big enough
        // to hit without looking, and a grid that sizes itself to its content leaves part of the
        // screen empty on a large phone while overflowing a small one.
        //
        // 🚨 A `.frame(minHeight:maxHeight:)` proposes a size — it does not forcibly clip a child
        // that refuses to shrink smaller, so the `ScrollView` is the backstop for a phone smaller
        // than this was tuned against: it scrolls a few points rather than clipping the bottom row.
        GeometryReader { proxy in
            ScrollView {
                grid(rowHeight: rowHeight(in: proxy.size.height))
                    .frame(minHeight: proxy.size.height, alignment: .top)
            }
        }
        .paiScreenBackground()
        .navigationTitle("Quick Actions")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("quick-actions-screen")
        .fixtureFact("quickActionsGrid", QuickActionLayout.summary)
        .fixtureFact(
            "quickActionsPutAway",
            QuickAction.allCases.filter(isPutAway).map(\.rawValue).joined(separator: ",")
        )
        #if DEBUG
            .task {
                if PaiFixtureLaunch.isEnabled(), PaiFixtureLaunch.opensQuickMore() { showingMore = true }
            }
        #endif
        .sheet(isPresented: $writingEntry) { MeComposerSheet(mode: .new) }
        .sheet(item: $editingShortcutSlot.map { slot in EditingSlot(slot: slot) }) { editing in
            ShortcutEditSheet(
                name: shortcutNameBinding(slot: editing.slot),
                urlString: shortcutURLBinding(slot: editing.slot)
            )
        }
        .sheet(
            isPresented: $showingMore,
            onDismiss: {
                let action = afterMore
                afterMore = nil
                action?()
            }
        ) {
            moreList
        }
    }

    private func grid(rowHeight: CGFloat) -> some View {
        VStack(spacing: spacing) {
            ForEach(Array(QuickActionLayout.grid.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, slot in
                        cell(slot, height: rowHeight)
                    }
                }
            }
        }
        .padding(padding)
    }

    @ViewBuilder
    private func cell(_ slot: QuickActionSlot, height: CGFloat) -> some View {
        switch slot {
        case .action(let action):
            if isAvailable(action) {
                actionTile(action, height: height)
            } else {
                Color.clear.frame(maxWidth: .infinity, minHeight: height)
            }
        case .more:
            tile(
                title: "More", subtitle: "Other actions", systemImage: "ellipsis.circle.fill",
                tint: PaiPalette.Semantic.textSecondary, height: height, identifier: "quick-more"
            ) {
                showingMore = true
            }
        case .empty:
            Color.clear.frame(maxWidth: .infinity, minHeight: height)
        }
    }

    /// Divided out of the measured height, then clamped. `GeometryReader` is what makes the grid
    /// fit a screen it was never tuned against; the clamp is what stops it stretching to fill one.
    private func rowHeight(in availableHeight: CGFloat) -> CGFloat {
        let divided = (availableHeight - padding * 2 - spacing * (rowCount - 1)) / rowCount
        return min(maxRowHeight, max(minRowHeight, divided))
    }

    /// Guests have no diary and no Me app, so those two slots stay empty for them.
    private func isAvailable(_ action: QuickAction) -> Bool {
        switch action {
        case .selfReport, .me: environment.connection?.me.capabilities.canOpenMe == true
        default: true
        }
    }

    private func tint(_ action: QuickAction) -> Color {
        switch action {
        case .selfReport, .fastSession, .fastCall: PaiPalette.amber500
        case .me, .computer, .home, .homeCall, .mailverdict: PaiPalette.primary500
        case .ultrafast, .ultrafastCall, .ultrafastCamera: PaiPalette.green500
        case .findNote, .newNote, .shortcut1, .shortcut2, .shortcut3: PaiPalette.Semantic.textSecondary
        }
    }

    private func identifier(_ action: QuickAction) -> String {
        switch action {
        case .selfReport: "quick-me"
        case .me: "quick-me-app"
        case .computer: "quick-computer"
        case .home: "quick-home"
        case .ultrafast: "quick-ultrafast"
        case .mailverdict: "quick-mailverdict-assistant"
        case .homeCall: "quick-home-call"
        case .ultrafastCamera: "quick-camera"
        case .ultrafastCall: "quick-ultrafast-call"
        case .fastSession: "quick-fast"
        case .fastCall: "quick-fast-call"
        case .findNote: "quick-find-note"
        case .newNote: "quick-new-note"
        case .shortcut1: "quick-shortcut-1"
        case .shortcut2: "quick-shortcut-2"
        case .shortcut3: "quick-shortcut-3"
        }
    }

    /// Whether `action` is put away: sleep mode is on and it leads into the agents. Its tile stays
    /// where it is, greyed with a moon, so the screen keeps the layout a thumb knows.
    private func isPutAway(_ action: QuickAction) -> Bool {
        environment.router.isAsleep && action.isNightBlocked
    }

    /// What a tap on `action` does, wherever its tile is drawn.
    private func perform(_ action: QuickAction) {
        // A habit-press on a put-away action lands on the sleep screen, which is the root.
        if isPutAway(action) {
            environment.router.popToRoot()
            return
        }
        switch action {
        case .selfReport:
            writingEntry = true
        case .me:
            environment.router.push(.me)
        case .computer:
            ComputerCallEntry.open(environment)
        case .mailverdict:
            MailVerdictAssistantEntry.open(environment: environment, drafts: drafts)
        case .findNote:
            NotesFilterFocus.shared.arm()
            environment.router.replace(with: [.notes])
        case .newNote:
            Task { await createNote() }
        case .shortcut1, .shortcut2, .shortcut3:
            guard let slot = action.shortcutSlot else { return }
            guard let url = shortcut(slot: slot).url else {
                editingShortcutSlot = slot
                return
            }
            UIApplication.shared.open(url)
        case .home, .ultrafast, .homeCall, .ultrafastCall, .ultrafastCamera, .fastSession, .fastCall:
            guard let type = action.sessionType else { return }
            NewSessionLaunch.start(
                type: type, call: action.startsCall, camera: action == .ultrafastCamera,
                environment: environment, drafts: drafts)
        }
    }

    @ViewBuilder
    private func actionTile(_ action: QuickAction, height: CGFloat) -> some View {
        let base = tile(
            title: action.title, subtitle: action.subtitle, systemImage: action.systemImage,
            tint: tint(action), height: height, identifier: identifier(action)
        ) {
            perform(action)
        }
        if action == .selfReport {
            base.overlay(alignment: .topTrailing) { selfReportDot }
        } else if isPutAway(action) {
            base
                .opacity(0.45)
                .overlay(alignment: .topTrailing) { moonBadge }
        } else {
            base
        }
    }

    private var moonBadge: some View {
        Image(systemName: "moon.zzz.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(PaiPalette.primary300)
            .padding(12)
            .accessibilityLabel("Resting until sleep mode ends")
            .accessibilityIdentifier("quick-moon-badge")
    }

    /// A take outlives the sheet, and nothing else on this screen shows one running; a small dot
    /// also marks a draft kept from last time.
    @ViewBuilder
    private var selfReportDot: some View {
        if environment.connection?.voice.isRecording(draftKey: SelfReportStore.dictationKey) == true {
            Circle()
                .fill(PaiPalette.Semantic.errorText)
                .frame(width: 8, height: 8)
                .padding(12)
                .accessibilityLabel("Recording")
                .accessibilityIdentifier("quick-me-recording-dot")
        } else if !selfReports.draft.isEmpty {
            Circle()
                .fill(PaiPalette.amber500)
                .frame(width: 6, height: 6)
                .padding(12)
                .accessibilityLabel("Draft kept")
                .accessibilityIdentifier("quick-me-draft-dot")
        }
    }

    // MARK: - More

    /// Every action the grid has no room for, one row each. Always the same list the layout
    /// reports, so an action added to ``QuickAction`` without a grid slot shows up here.
    private var moreList: some View {
        NavigationStack {
            List {
                ForEach(QuickActionLayout.overflow.filter(isAvailable), id: \.self) { action in
                    moreRow(action)
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("quick-more-list")
            .fixtureFact(
                "quickMoreList", QuickActionLayout.overflow.filter(isAvailable).map(\.rawValue).joined(separator: ",")
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingMore = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func moreRow(_ action: QuickAction) -> some View {
        let shortcut = action.shortcutSlot.map { shortcut(slot: $0) }
        let title =
            shortcut.map { $0.isConfigured ? ($0.name.isEmpty ? "Shortcut" : $0.name) : "Set up" } ?? action.title
        let subtitle = shortcut.map { $0.isConfigured ? "Todoist" : "Tap to add" } ?? action.subtitle
        return Button {
            afterMore = { perform(action) }
            showingMore = false
        } label: {
            HStack(spacing: 14) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint(action))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(PaiTypography.panelTitle.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    Text(subtitle)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isPutAway(action) ? 0.45 : 1)
            .overlay(alignment: .trailing) { if isPutAway(action) { moonBadge } }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifier(action))-row")
        .accessibilityLabel("\(title), \(subtitle)")
        .contextMenu {
            if let slot = action.shortcutSlot {
                Button("Edit shortcut", systemImage: "pencil") {
                    afterMore = { editingShortcutSlot = slot }
                    showingMore = false
                }
            }
        }
    }

    private func tile(
        title: String, subtitle: String, systemImage: String, tint: Color, height: CGFloat,
        identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(title)
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            // Claims the whole tile. A plain `Button` is hit-tested against what it draws, so a
            // label with a `Spacer` in it answers a tap on the text and ignores the empty space
            // around it — which on a control this size is most of it.
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    private func createNote() async {
        guard let created = await notes.createNote(name: NoteNaming.todayName()) else {
            toasts.show(notes.loadError ?? "Could not create the note")
            return
        }
        NoteCreationFocus.shared.markCreated(id: created.id)
        environment.router.replace(with: [.notes, .note(id: created.id)])
    }
}

/// `.sheet(item:)` needs an `Identifiable` — a bare `Int?` slot number wrapped just enough to be
/// one, so a *different* slot opening while the sheet is already up gets a fresh identity.
private struct EditingSlot: Identifiable, Equatable {
    let slot: Int
    var id: Int { slot }
}

extension Binding<Int?> {
    /// Maps an optional binding through a transform, for `.sheet(item:)` over a plain `Int?`
    /// state that is not itself `Identifiable`.
    fileprivate func map<T>(_ transform: @escaping (Int) -> T) -> Binding<T?> {
        Binding<T?>(
            get: { self.wrappedValue.map(transform) },
            set: { newValue in if newValue == nil { self.wrappedValue = nil } }
        )
    }
}

/// The name + link editor a long press (or an unconfigured tap) opens.
private struct ShortcutEditSheet: View {
    @Binding var name: String
    @Binding var urlString: String
    @Environment(\.dismiss) private var dismiss

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
                    Text("Paste a Todoist view or saved-filter link. Opens in the Todoist app if it's installed.")
                }
            }
            .navigationTitle("Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
