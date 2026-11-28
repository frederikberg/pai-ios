import PAIKit
import SwiftUI

/// Where the hardware Action Button lands: a grid of the user's own arrangement
/// (``QuickActionsStore``), three columns and five rows on screen, the rest reached by scrolling,
/// with the More tile opening the actions put behind it.
///
/// The button is pressed without looking, so the shape stays fixed: every tile has the same size,
/// divided out of the screen so five rows fill it, and a tile's position only changes when the user
/// moves it. A long press on any tile offers the Actions Library, where the arrangement is edited.
/// Nothing here loads, so there is no state in which the grid is not yet tappable.
struct QuickActionsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NotesStore.self) private var notes
    @Environment(DraftStore.self) private var drafts
    @Environment(ToastCenter.self) private var toasts
    @Environment(SelfReportStore.self) private var selfReports

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16

    @State private var writingEntry = false
    @State private var showingMore = false
    @State private var showingLibrary = false
    @State private var editingShortcut: QuickActionShortcut?
    /// What a tap in the More list asked for. It runs once the list has finished leaving: an
    /// action that presents or navigates from behind a dismissing sheet is dropped silently.
    @State private var afterMore: (() -> Void)?
    @State private var choosingPushPause = false

    private var store: QuickActionsStore { environment.quickActions }
    private var capabilities: Capabilities { environment.connection?.me.capabilities ?? .unknown }

    /// Whether this person can use `item`: an action they may open, a shortcut that exists.
    private func isUsable(_ item: QuickActionItem) -> Bool {
        switch item {
        case .action(let action): action.isAvailable(to: capabilities)
        case .shortcut(let id): store.shortcut(id) != nil
        case .todosPage: capabilities.canOpenTodos
        case .more: false
        }
    }

    private var moreItems: [QuickActionItem] { store.more.filter(isUsable) }

    /// The grid as drawn: unusable items left out rather than leaving holes, the More tile only
    /// while More holds something.
    private var gridItems: [QuickActionItem] {
        let hasMore = !moreItems.isEmpty
        return store.grid.filter { $0 == .more ? hasMore : isUsable($0) }
    }

    private var gridSummary: String { gridItems.map(\.summaryName).joined(separator: ",") }
    private var putAwaySummary: String {
        (gridItems + moreItems).filter(isPutAway).map(\.summaryName).joined(separator: ",")
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if gridItems.isEmpty {
                        emptyGrid
                    } else {
                        grid(tileHeight: tileHeight(in: proxy.size.height))
                    }
                    Color.clear.frame(height: 0).id(FixtureScrollAnchor.quickGridEnd.rawValue)
                }
            }
            // Fifteen tiles fill the screen exactly; only a sixth row makes it scroll.
            .scrollBounceBehavior(.basedOnSize)
            .fixtureScrollsToAnchor()
        }
        .paiScreenBackground()
        .navigationTitle("Quick Actions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingLibrary = true }
                    .accessibilityIdentifier("quick-edit")
            }
        }
        .accessibilityIdentifier("quick-actions-screen")
        .fixtureFact("quickActionsGrid", gridSummary)
        .fixtureFact("quickActionsPutAway", putAwaySummary)
        #if DEBUG
            .task {
                guard PaiFixtureLaunch.isEnabled() else { return }
                if PaiFixtureLaunch.opensQuickMore() { showingMore = true }
                if PaiFixtureLaunch.requestedQuickEdit() != nil { showingLibrary = true }
            }
        #endif
        .sheet(isPresented: $writingEntry) { MeComposerSheet(mode: .new) }
        // Whether push is paused is the server's to say; read when the action is on show.
        .task {
            guard store.placement(of: .action(.pauseNotifications)) != .hidden else { return }
            await pushDevices?.load()
        }
        .confirmationDialog("Pause push to this iPhone", isPresented: $choosingPushPause, titleVisibility: .visible) {
            ForEach(PushPausePreset.presets(now: Date(), zone: .current)) { preset in
                Button(preset.label) { Task { await pausePush(until: preset.until) } }
            }
        } message: {
            Text("The inbox keeps everything. Nothing is caught up after a pause.")
        }
        .sheet(item: $editingShortcut) { shortcut in
            ShortcutEditSheet(
                shortcut: shortcut,
                onSave: { store.updateShortcut($0) },
                onDelete: { store.deleteShortcut(shortcut.id) })
        }
        .sheet(isPresented: $showingLibrary) {
            QuickActionsLibrarySheet(store: store, capabilities: capabilities)
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

    private func tileHeight(in viewportHeight: CGFloat) -> CGFloat {
        CGFloat(
            QuickActionGrid.tileHeight(
                viewportHeight: Double(viewportHeight), padding: Double(padding), spacing: Double(spacing)))
    }

    private func grid(tileHeight: CGFloat) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: spacing), count: QuickActionGrid.columns),
            spacing: spacing
        ) {
            ForEach(gridItems, id: \.self) { item in
                tile(for: item, height: tileHeight)
            }
        }
        .padding(padding)
    }

    private var emptyGrid: some View {
        VStack(spacing: 12) {
            Text("Nothing on the grid")
                .font(PaiTypography.panelTitle.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            Button("Open the Actions Library") { showingLibrary = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Tiles

    /// A tile and its long press.
    private func tile(for item: QuickActionItem, height: CGFloat) -> some View {
        tileContent(for: item, height: height)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
            .contextMenu { tileMenu(for: item) }
    }

    @ViewBuilder
    private func tileContent(for item: QuickActionItem, height: CGFloat) -> some View {
        switch item {
        case .action(let action):
            actionTile(action, height: height)
        case .shortcut(let id):
            if let shortcut = store.shortcut(id) {
                tile(
                    title: shortcut.title, subtitle: shortcut.subtitle, systemImage: "arrow.up.forward.app",
                    tint: PaiPalette.Semantic.textSecondary, height: height,
                    identifier: "quick-shortcut-\(shortcut.title)"
                ) {
                    open(shortcut)
                }
            }
        case .todosPage(let key):
            if let page = TodoPage(key: key) {
                let entry = todosEntry(page)
                tile(
                    title: entry?.title ?? "Todos view", subtitle: todosKind(page), systemImage: "checklist",
                    tint: PaiPalette.Semantic.textSecondary, height: height, identifier: "quick-todos-page"
                ) {
                    TodosEntry.open(page)
                }
            }
        case .more:
            tile(
                title: "More", subtitle: "Other actions", systemImage: "ellipsis.circle.fill",
                tint: PaiPalette.Semantic.textSecondary, height: height, identifier: "quick-more"
            ) {
                showingMore = true
            }
        }
    }

    /// What a long press on a tile offers. Mirrors the home screen's own long press: the way into
    /// editing, and for a shortcut its own editor.
    @ViewBuilder
    private func tileMenu(for item: QuickActionItem) -> some View {
        Button("Edit Quick Actions", systemImage: "square.grid.3x3") { showingLibrary = true }
        if case .shortcut(let id) = item, let shortcut = store.shortcut(id) {
            Button("Edit shortcut", systemImage: "pencil") { editingShortcut = shortcut }
        }
    }

    private func tint(_ action: QuickAction) -> Color {
        switch action {
        case .selfReport, .fastSession, .fastCall: PaiPalette.amber500
        case .me, .computer, .home, .homeCall, .mailverdict: PaiPalette.primary500
        case .ultrafast, .ultrafastCall, .ultrafastCamera: PaiPalette.green500
        case .pauseNotifications:
            pushPausedUntil == nil ? PaiPalette.Semantic.textSecondary : PaiPalette.amber500
        case .findNote, .newNote, .notes, .alarm, .weather, .canteen, .scheduler, .decisions, .usage,
            .cameraImport, .todos, .newTodo, .searchTodos, .todosSwitcher, .todosDesk:
            PaiPalette.Semantic.textSecondary
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
        case .notes, .alarm, .weather, .canteen, .scheduler, .decisions, .usage, .cameraImport, .todos, .newTodo,
            .searchTodos, .todosSwitcher, .todosDesk, .pauseNotifications:
            "quick-\(action.rawValue)"
        }
    }

    /// Whether `item` is put away: sleep mode is on and it leads into the agents. Its tile stays
    /// where it is, greyed with a moon, so the screen keeps the layout a thumb knows.
    private func isPutAway(_ item: QuickActionItem) -> Bool {
        environment.router.isAsleep && item.isNightBlocked
    }

    private func open(_ shortcut: QuickActionShortcut) {
        guard let url = shortcut.url else {
            editingShortcut = shortcut
            return
        }
        UIApplication.shared.open(url)
    }

    /// What a tap on `action` does, wherever its tile is drawn.
    private func perform(_ action: QuickAction) {
        // A habit-press on a put-away action lands on the sleep screen, which is the root.
        if isPutAway(.action(action)) {
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
        case .todos: TodosEntry.open(environment)
        case .newTodo: TodosEntry.newTodo()
        case .searchTodos: TodosEntry.search(environment)
        case .todosSwitcher: TodosEntry.openSwitcher(environment)
        case .todosDesk: TodosEntry.openDesk(environment)
        case .pauseNotifications: Task { await togglePushPause() }
        case .notes, .alarm, .weather, .canteen, .scheduler, .decisions, .usage, .cameraImport:
            guard let route = action.appEntry?.route else { return }
            environment.router.push(route)
        case .home, .ultrafast, .homeCall, .ultrafastCall, .ultrafastCamera, .fastSession, .fastCall:
            guard let type = action.sessionType else { return }
            NewSessionLaunch.start(
                type: type, call: action.startsCall, camera: action == .ultrafastCamera,
                environment: environment, drafts: drafts)
        }
    }

    // MARK: Pausing push

    private var pushDevices: PushDevicesStore? { environment.connection?.settings.pushDevices }

    /// When this iPhone's pause ends, while it is paused.
    private var pushPausedUntil: Date? { pushDevices?.thisDevice?.pausedUntilDate(after: Date()) }

    private func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// A tap on the pause action: a paused phone resumes, any other is asked for how long.
    private func togglePushPause() async {
        guard let devices = pushDevices else { return }
        if devices.thisDevice == nil { await devices.load() }
        guard let phone = devices.thisDevice else {
            toasts.show(
                devices.errorMessage ?? "This iPhone receives no push yet. Turn it on in Settings, Notifications.")
            return
        }
        guard phone.pausedUntilDate(after: Date()) != nil else {
            choosingPushPause = true
            return
        }
        await devices.resume(phone)
        toasts.show(devices.errorMessage ?? "Push to this iPhone is on again")
    }

    private func pausePush(until: Date) async {
        guard let devices = pushDevices, let phone = devices.thisDevice else { return }
        await devices.pause(phone, until: until)
        toasts.show(devices.errorMessage ?? "Push to this iPhone is paused until \(clock(until))")
    }

    /// The pause action says what a tap does next, and until when the phone is quiet.
    private func title(of action: QuickAction) -> String {
        action == .pauseNotifications && pushPausedUntil != nil ? "Resume push" : action.title
    }

    private func subtitle(of action: QuickAction) -> String {
        guard action == .pauseNotifications, let until = pushPausedUntil else { return action.subtitle }
        return "Paused until \(clock(until))"
    }

    @ViewBuilder
    private func actionTile(_ action: QuickAction, height: CGFloat) -> some View {
        let base = tile(
            title: title(of: action), subtitle: subtitle(of: action), systemImage: action.systemImage,
            tint: tint(action), height: height, identifier: identifier(action)
        ) {
            perform(action)
        }
        if action == .selfReport {
            base.overlay(alignment: .topTrailing) { selfReportDot }
        } else if isPutAway(.action(action)) {
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

    /// The items the user put in More, in their order.
    private var moreList: some View {
        NavigationStack {
            List {
                ForEach(moreItems, id: \.self) { item in
                    moreRow(item)
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("quick-more-list")
            .fixtureFact("quickMoreList", moreItems.map(\.summaryName).joined(separator: ","))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingMore = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Runs `work` once the More list has left.
    private func afterClosingMore(_ work: @escaping () -> Void) {
        afterMore = work
        showingMore = false
    }

    @ViewBuilder
    private func moreRow(_ item: QuickActionItem) -> some View {
        switch item {
        case .action(let action):
            moreRow(
                title: title(of: action), subtitle: subtitle(of: action), systemImage: action.systemImage,
                tint: tint(action), identifier: "\(identifier(action))-row", putAway: isPutAway(item)
            ) {
                afterClosingMore { perform(action) }
            }
            .contextMenu {
                Button("Edit Quick Actions", systemImage: "square.grid.3x3") {
                    afterClosingMore { showingLibrary = true }
                }
            }
        case .shortcut(let id):
            if let shortcut = store.shortcut(id) {
                moreRow(
                    title: shortcut.title, subtitle: shortcut.subtitle, systemImage: "arrow.up.forward.app",
                    tint: PaiPalette.Semantic.textSecondary, identifier: "quick-shortcut-\(shortcut.title)-row",
                    putAway: false
                ) {
                    afterClosingMore { open(shortcut) }
                }
                .contextMenu {
                    Button("Edit Quick Actions", systemImage: "square.grid.3x3") {
                        afterClosingMore { showingLibrary = true }
                    }
                    Button("Edit shortcut", systemImage: "pencil") {
                        afterClosingMore { editingShortcut = shortcut }
                    }
                }
            }
        case .todosPage(let key):
            if let page = TodoPage(key: key) {
                moreRow(
                    title: todosEntry(page)?.title ?? "Todos view", subtitle: todosKind(page), systemImage: "checklist",
                    tint: PaiPalette.Semantic.textSecondary, identifier: "quick-todos-page-row", putAway: false
                ) {
                    afterClosingMore { TodosEntry.open(page) }
                }
            }
        case .more:
            EmptyView()
        }
    }

    /// A Todos view or list as Todos names it, from what the phone last read.
    private func todosEntry(_ page: TodoPage) -> TodoBrowse.Entry? {
        TodoBrowse.make(me: environment.todos.me, viewCounts: [:]).entry(for: page)
    }

    private func todosKind(_ page: TodoPage) -> String {
        switch page {
        case .view: "Todos view"
        case .list: "Todos list"
        case .tag: "Todos tag"
        }
    }

    private func moreRow(
        title: String, subtitle: String, systemImage: String, tint: Color, identifier: String, putAway: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
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
            .opacity(putAway ? 0.45 : 1)
            .overlay(alignment: .trailing) { if putAway { moonBadge } }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    /// One tile. Its height is set exactly, not as a minimum, so every tile on the grid has the
    /// same size whatever its text.
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
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
