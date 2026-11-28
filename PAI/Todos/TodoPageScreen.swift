import PAIKit
import SwiftUI

/// A Todos page: a saved view, a list or a tag, with the desk above it and its name in the bar. `nil`
/// is Todos' home, the first favourite view (Today). Rows tick from their circle or a swipe left,
/// go on the desk with a swipe right, and open their subtasks from the chevron. Every write is a
/// change in the outbox, so ticking works without a connection.
///
/// A long press on a row offers Select: the rows then carry a selection mark, a tap switches it,
/// and a bar on the bottom changes everything selected in one change with one Undo.
struct TodoPageScreen: View {
    let page: TodoPage?

    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @State private var expanded: Set<String> = []
    @State private var deskMode: TodoDeskMode = .bar
    @State private var adding = false
    @State private var addText: String?
    @State private var addMode: TodoAddMode = .line
    @State private var ticks = 0
    @State private var opened: TodoSheetTarget?
    /// Whether the open todo came from this page's own rows, whose view's defaults its subtasks get.
    @State private var openedFromRows = false
    @State private var addSection: TodoAddDeskSection?
    @State private var switching = false
    @State private var fronts = 0
    @Environment(\.scenePhase) private var scenePhase
    @State private var switchQuery: String?
    @State private var showsSettings = false
    /// The todos being selected; nil outside select mode.
    @State private var selection: Set<String>?
    /// The picker open in the selection's bar.
    @State private var bulkPicker: TodoPicker?
    /// Whether Upcoming has been put on its first day ahead, with the days behind above it.
    @State private var startedAhead = false

    private var store: TodosStore { environment.todos }

    /// The page shown: the one asked for, or the home view once `/me` names it.
    private var resolved: TodoPage? {
        page ?? TodoBrowse.home(store.me).map { .view($0.id) }
    }

    private var view: TodoView? {
        guard case .view(let id) = resolved else { return nil }
        return store.me?.views.first { $0.id == id }
    }

    private var list: TodoList? {
        guard case .list(let id) = resolved else { return nil }
        return store.lists.first { $0.id == id }
    }

    private var chosenTags: [String: TodoColor] { TodoIdentity.chosenTagColors(store.me?.tags ?? []) }

    private func tagColor(_ name: String) -> TodoColor { TodoIdentity.tagColor(name, chosen: chosenTags) }

    private var identity: TodoIdentity {
        if let view { return TodoIdentity.of(view: view, tagColor: tagColor) }
        if let list { return TodoIdentity.of(list: list) }
        if case .tag(let name) = resolved { return TodoIdentity(icon: .hash, color: tagColor(name)) }
        return TodoIdentity(icon: .sun, color: .amber)
    }

    private var title: String {
        if let view { return view.name }
        if let list { return list.name }
        if case .tag(let name) = resolved { return name }
        return "Todos"
    }

    private var result: TodoPageResult? { resolved.flatMap { store.results[$0.key] } }

    /// The page's number: a list's open todos, a view's count, else the rows it read.
    private var count: Int? {
        if let list { return list.counts.open }
        if let view, let counted = store.viewCounts[view.id] { return counted }
        return result?.total
    }

    private var deskKind: TodoDeskPageKind { list != nil ? .list : TodoDeskPageKind.of(view: view) }

    /// A checklist's rows are one line.
    private var compact: Bool { list?.layout == "checklist" || view?.layout == "checklist" }

    private var rows: [TodoListRow] {
        TodoRows.build(
            result: result, pending: resolved.map { store.pendingRows(on: $0) } ?? [], todos: store.todos,
            expanded: expanded, children: store.childIds, groupBy: view?.groupBy)
    }

    /// The page's rows span more than one list, so each row names its own.
    private var spansLists: Bool {
        var lists = Set<String>()
        for case .todo(let id, _, _, _) in rows {
            if let todo = store.todos[id] { lists.insert(todo.listId) }
        }
        return lists.count > 1
    }

    private func rowModel(_ todo: Todo) -> TodoRowModel {
        let ownList = spansLists ? store.lists.first { $0.id == todo.listId } : nil
        return TodoRowModel.make(
            todo, today: store.day, clock: store.personsClock, tagColor: tagColor, list: ownList)
    }

    private var place: TodoCreatePlace {
        TodoCreatePlace(defaults: view?.defaults, listId: list?.id, page: resolved?.key)
    }

    /// Asked again whenever the page comes to the front (shown again after another screen, or the
    /// app back from the background) as well as after a change, so it is never left stale.
    private var loadKey: String { "\(resolved?.key ?? "")#\(store.readTick)#\(fronts)" }

    var body: some View {
        TodoDeskPanel(
            todos: store, mode: $deskMode, listTitle: title, listCount: count, rowModel: rowModel,
            onTick: tick, onOpen: { open($0) },
            onAddHere: { section in
                addSection = section
                startAdding(.line)
            }
        ) {
            pageList
        }
        // Above the line the list folds to while the desk takes the whole height. The selection's
        // bar takes the bottom while todos are being selected.
        .overlay(alignment: .bottomTrailing) {
            if selection == nil { addButton.padding(.bottom, deskMode == .desk ? 44 : 0) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection != nil { selectionBar }
        }
        // The bar names the view being shown, which the list's own heading stops doing once it
        // is scrolled away or folded under the desk.
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.todosSearch)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search")
            }
            // Go anywhere in Todos by typing its name.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    switching = true
                } label: {
                    Image(systemName: "text.magnifyingglass")
                }
                .accessibilityLabel("Go to a view, list or tag")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.todosBrowse)
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel("Views and lists")
            }
        }
        .sheet(isPresented: $switching) {
            TodoSwitcherSheet(onPick: go, initialQuery: switchQuery ?? fixtureSwitch ?? "")
        }
        .navigationDestination(isPresented: $showsSettings) { TodoSettingsScreen() }
        .fullScreenCover(isPresented: $adding, onDismiss: { addSection = nil }) {
            TodoAddSheet(
                todos: store,
                draft: TodoCaptureDraft(text: addText ?? fixtureAdd?.text ?? "") {
                    [client = environment.connection?.apiClient, listId = list?.id] text in
                    guard let client else { throw PaiError.transport("Not signed in") }
                    return try await client.todosParse(text: text, list: listId, source: .ios)
                },
                place: place, placeName: title, deskSection: addSection, initialText: addText ?? fixtureAdd?.text,
                initialMode: addText == nil
                    ? (fixtureAdd?.mode ?? addMode) : addMode, onOpen: openAdded,
                onComposed: openComposed)
        }
        .sheet(item: $opened) { target in
            TodoSheetView(todoId: target.id, viewDefaults: openedFromRows ? view?.defaults : nil)
        }
        .sensoryFeedback(.success, trigger: ticks)
        .task(id: deskKind) { deskMode = startingDeskMode() }
        .onChange(of: environment.todosPlace.fullDeskWanted) { _, wanted in
            if wanted, environment.todosPlace.takeFullDesk() { deskMode = .desk }
        }
        .onChange(of: environment.todosPlace.switcherWanted, initial: true) { _, wanted in
            if wanted, environment.todosPlace.takeSwitcher() { switching = true }
        }
        .task(id: resolved?.key) { if let resolved { environment.todosPlace.shown(resolved) } }
        .onChange(of: deskMode) { _, mode in environment.todoDeskModes.set(mode, for: deskKind) }
        .task(id: loadKey) { await load() }
        .onAppear { fronts += 1 }
        .onChange(of: scenePhase) { _, phase in if phase == .active { fronts += 1 } }
        .task { openFixtureState() }
        .task(id: rows.count) { tickForFixture() }
        .task(id: fixtureSelectKey) { selectForFixture() }
        .fixtureFact("todosSelected", selectedFact)
        .fixtureFact("todosPage", title)
        .fixtureFact("todosDeskMode", deskMode.rawValue)
        .fixtureFact("todosRows", String(rows.count))
        .fixtureFact("todosDeskCards", String(store.deskItems.filter { $0.kind == .todo }.count))
    }

    /// Upcoming and the Logbook are day screens; every other layout is a list of rows.
    private var dayLayout: String? {
        guard let layout = view?.layout, layout == "agenda" || layout == "log" else { return nil }
        return layout
    }

    /// Upcoming's first day ahead, when days behind stand above it.
    private var upcomingStart: String? {
        guard dayLayout == "agenda", let upcoming = store.upcoming, !upcoming.earlier.isEmpty else { return nil }
        return upcoming.days.first.map { TodoDays.dayKey($0.date) }
    }

    private var pageList: some View {
        ScrollViewReader { proxy in
            List {
                header
                    .listRowSeparator(.hidden)
                if let dayLayout {
                    TodoDayRows(
                        layout: dayLayout, rowModel: rowModel, onTick: tick, onOpen: { open($0) }, selection: selection,
                        onSelect: { (id: String) in toggleSelected(id) },
                        onStartSelecting: { (id: String) in startSelecting(id) })
                } else {
                    pageRows
                }
            }
            .listStyle(.plain)
            .refreshable { await load() }
            // Upcoming opens on the first day ahead; today and the days behind are a scroll up.
            .task(id: upcomingStart) {
                guard let upcomingStart, !startedAhead else { return }
                startedAhead = true
                await Task.yield()
                proxy.scrollTo(upcomingStart, anchor: .top)
            }
        }
    }

    @ViewBuilder private var pageRows: some View {
        if let blocked = TodoPermissions.tickBlockedReason(list) {
            Label(blocked, systemImage: "lock")
                .font(.footnote)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .listRowSeparator(.hidden)
        }
        ForEach(rows) { row in
            rowView(row)
        }
        footer
            .listRowSeparator(.hidden)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TodoIdentityIcon(identity: identity, size: 22)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(PaiPalette.Semantic.textStrong)
                .lineLimit(1)
            if let count {
                Text("\(count)").font(.title3).monospacedDigit().foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func rowView(_ row: TodoListRow) -> some View {
        switch row {
        case .heading(_, let label, let count):
            HStack(spacing: 6) {
                Text(label.uppercased()).font(.caption.weight(.semibold))
                Text("\(count)").font(.caption).monospacedDigit()
            }
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .padding(.top, 10)
            .listRowSeparator(.hidden)
        case .todo(let id, let depth, let expandable, let isExpanded):
            if let todo = store.todos[id] {
                todoRow(todo, depth: depth, expandable: expandable, isExpanded: isExpanded)
            }
        }
    }

    /// A todo's row. While todos are being selected it carries the selection mark and no swipes.
    @ViewBuilder private func todoRow(_ todo: Todo, depth: Int, expandable: Bool, isExpanded: Bool) -> some View {
        let id = todo.id
        let isSelected: Bool? = selection.map { $0.contains(id) }
        let highlight: Color? = isSelected == true ? PaiPalette.primary500.opacity(0.12) : nil
        TodoRowView(
            model: rowModel(todo), depth: depth, expandable: expandable, expanded: isExpanded, compact: compact,
            onTick: { tick(id) }, onToggleExpanded: { toggleExpanded(id) }, onOpen: { open(id, fromRows: true) },
            selected: isSelected, onSelect: { toggleSelected(id) }
        )
        .opacity(store.pendingIds.contains(id) ? 0.75 : 1)
        .listRowBackground(highlight)
        .contextMenu {
            if selection == nil {
                Button("Select", systemImage: "checkmark.circle") { startSelecting(id) }
            }
        }
        .swipeActions(edge: .leading) {
            if selection == nil {
                Button {
                    store.setOnDesk(todoId: id, !todo.onDesk)
                } label: {
                    Label(todo.onDesk ? "Off the desk" : "Desk", systemImage: todo.onDesk ? "pin.slash" : "pin")
                }
                .tint(PaiPalette.primary500)
            }
        }
        .swipeActions(edge: .trailing) {
            if selection == nil {
                Button {
                    tick(id)
                } label: {
                    Label(todo.status == .open ? "Done" : "Reopen", systemImage: "checkmark")
                }
                .tint(PaiPalette.green500)
            }
        }
    }

    // MARK: - Selecting

    /// The todos the page shows, in its order: what "All" selects and what an action runs over.
    private var visibleIds: [String] {
        var ids: [String] = []
        var seen = Set<String>()
        if dayLayout == "agenda" {
            guard let upcoming = store.upcoming else { return [] }
            let dayRows = TodoDays.upcomingRows(
                upcoming, todos: store.todos, today: store.personsToday, pending: store.queue)
            for case .todo(_, let id) in dayRows where seen.insert(id).inserted { ids.append(id) }
        } else if dayLayout == nil {
            for case .todo(let id, _, _, _) in rows where seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    /// The selected todos still on the page, in its order: the bar's number is what an action hits.
    private var selectedIds: [String] {
        guard let selection else { return [] }
        return visibleIds.filter { (id: String) in selection.contains(id) }
    }

    private func startSelecting(_ id: String) {
        selection = [id]
    }

    private func toggleSelected(_ id: String) {
        guard var chosen = selection else { return }
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
        selection = chosen
    }

    private func endSelecting() {
        bulkPicker = nil
        selection = nil
    }

    /// One change for the action on everything selected, said with Undo. What this person may
    /// not change is left out, and a toast says how many and why. A picker keeps the selection
    /// for its next pick; an action of the bar itself ends it.
    private func runBulk(_ action: TodoBulk.Action, keepsSelection: Bool) {
        let plan = TodoBulk.plan(action, ids: selectedIds, todos: store.todos, lists: store.lists)
        if let leftOut = plan.leftOut { toasts.show(leftOut, kind: .info) }
        guard let change = plan.change else { return }
        TodoUndoToast.show(change.toast, changeId: store.submit(change.ops), store: store, toasts: toasts)
        ticks += 1
        if !keepsSelection { endSelecting() }
    }

    /// What the bar's pickers change: every choice is one change over the whole selection.
    private var bulkEditing: TodoFieldEditing {
        TodoFieldEditing(
            values: TodoBulk.common(selectedIds, todos: store.todos), today: store.personsToday,
            setWhen: { (when: TodoWhen?) in runBulk(TodoBulk.Action.when(when), keepsSelection: true) },
            setSomeday: { (on: Bool) in runBulk(TodoBulk.Action.someday(on), keepsSelection: true) },
            setRepeat: { (rule: [String: PaiJSONValue]?) in
                runBulk(TodoBulk.Action.repeatRule(rule), keepsSelection: true)
            },
            setDeadline: { (deadline: TodoDeadline?) in
                runBulk(TodoBulk.Action.deadline(date: deadline?.date), keepsSelection: true)
            },
            setHorizon: { (horizon: TodoHorizon) in runBulk(TodoBulk.Action.horizon(horizon), keepsSelection: true) },
            setTag: { (name: String, on: Bool) in
                let action: TodoBulk.Action = on ? .tag(name) : .untag(name)
                runBulk(action, keepsSelection: true)
            },
            setList: { (list: String) in runBulk(TodoBulk.Action.move(list: list), keepsSelection: true) },
            setDesk: { (_: Bool) in runBulk(TodoBulk.Action.desk, keepsSelection: true) },
            addNudge: { (choice: TodoFieldOps.NudgeChoice) in
                runBulk(TodoBulk.Action.nudge(choice), keepsSelection: true)
            },
            removeNudge: { (_: String) in })
    }

    private var selectionBar: TodoSelectionBar {
        let chosen: [String] = selectedIds
        let open: [String] = chosen.filter { (id: String) in store.todos[id]?.status == .open }
        let reopens: Bool = !chosen.isEmpty && open.isEmpty
        return TodoSelectionBar(
            count: chosen.count, visibleCount: visibleIds.count, reopens: reopens, picker: bulkPicker,
            editing: bulkEditing,
            onAll: { selection = Set(visibleIds) },
            onEnd: { endSelecting() },
            onAction: { (action: TodoBulk.Action) in runBulk(action, keepsSelection: false) },
            onPick: { (next: TodoPicker?) in bulkPicker = next })
    }

    private var selectedFact: String {
        guard let selection else { return "" }
        return String(selection.count)
    }

    /// Moves when the rows a fixture launch selects from have arrived.
    private var fixtureSelectKey: String {
        let days: Int = store.upcoming?.days.count ?? 0
        return "\(rows.count)#\(days)"
    }

    private func selectForFixture() {
        #if DEBUG
            guard selection == nil, let count = PaiFixtureLaunch.requestedTodosSelect(), !visibleIds.isEmpty else {
                return
            }
            selection = Set(visibleIds.prefix(count))
            bulkPicker = PaiFixtureLaunch.requestedTodosPicker().flatMap { TodoPicker(rawValue: $0) }
        #endif
    }

    @ViewBuilder private var footer: some View {
        if let resolved, let error = store.resultErrors[resolved.key] {
            Text(error).font(.footnote).foregroundStyle(PaiPalette.Semantic.textMuted)
        } else if result == nil {
            ProgressView().frame(maxWidth: .infinity)
        } else if rows.isEmpty {
            Text("Nothing here.").font(.footnote).foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        if let resolved, result?.nextCursor != nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .task { await store.loadMore(resolved) }
        }
        Color.clear.frame(height: 72)
    }

    /// A tap adds one line; a long press also offers describing it in plain words.
    private var addButton: some View {
        Button {
            startAdding(.line)
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(PaiPalette.primary500))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
        .contextMenu {
            Button("New todo", systemImage: "plus") { startAdding(.line) }
            Button("Describe it", systemImage: "sparkles") { startAdding(.describe) }
        }
        .padding(20)
        .accessibilityLabel("New todo")
    }

    /// The add sheet a fixture launch asks for, read from the launch arguments each time: the
    /// page can be built again while its sheet is up (the home resolves once `/me` is read), and
    /// the sheet then still gets the same words and mode.
    private var fixtureAdd: (text: String, mode: TodoAddMode)? {
        #if DEBUG
            if let text = PaiFixtureLaunch.requestedTodosDescribe() { return (text, .describe) }
            if let text = PaiFixtureLaunch.requestedTodosAdd() { return (text, .line) }
        #endif
        return nil
    }

    /// A pick in the switcher: its page, or Todos' settings.
    private func go(_ page: TodoPage?) {
        if let page { environment.router.push(.todosPage(page)) } else { showsSettings = true }
    }

    /// The switcher's query a fixture launch asks for, read from the launch arguments each time,
    /// like `fixtureAdd`: a page built again while the sheet is up hands it the same words.
    private var fixtureSwitch: String? {
        #if DEBUG
            return PaiFixtureLaunch.requestedTodosSwitch()
        #else
            return nil
        #endif
    }

    private func startAdding(_ mode: TodoAddMode, text: String? = nil) {
        addText = text
        addMode = mode
        adding = true
    }

    /// Plain words became todos: once the server has them, the first one opens, so a guess the
    /// model made is one tap from being changed. Several say how many came in.
    private func openComposed(_ composed: TodosComposed) {
        Task {
            // The add sheet is still leaving; a sheet asked for meanwhile is dropped.
            try? await Task.sleep(for: .milliseconds(700))
            switch await store.settled(composed.changeId, timeout: 15) {
            case .applied:
                if composed.count > 1 {
                    TodoUndoToast.show(
                        "Added \(composed.count) todos", changeId: composed.changeId, store: store, toasts: toasts)
                }
                open(composed.firstTodoId)
            case .refused(let refusal):
                toasts.show("Not added: \(refusal.message)", kind: .error)
            case .waiting:
                toasts.show("Saved on this iPhone. It is added once there is a connection.", kind: .info)
            }
        }
    }

    private func tick(_ id: String) {
        guard let todo = store.todos[id] else { return }
        let own = store.lists.first { $0.id == todo.listId }
        if let blocked = TodoPermissions.tickBlockedReason(own) {
            toasts.show(blocked, kind: .error)
            return
        }
        TodoUndoToast.toggleDone(todo, store: store, toasts: toasts)
        ticks += 1
    }

    /// `fromRows` says the todo is one of this page's own rows, so the view shows it.
    private func open(_ id: String, fromRows: Bool = false) {
        openedFromRows = fromRows
        opened = TodoSheetTarget(id: id)
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
            Task { await store.loadChildren(of: id) }
        }
    }

    private func load() async {
        if let dayLayout {
            if dayLayout == "agenda" { await store.loadUpcoming() } else { await store.loadLogbook() }
            return
        }
        guard let resolved else { return }
        await store.loadPage(resolved)
        for id in expanded { await store.loadChildren(of: id) }
        await store.refreshViewCounts()
    }

    private func startingDeskMode() -> TodoDeskMode {
        if environment.todosPlace.takeFullDesk() { return .desk }
        #if DEBUG
            if let mode = PaiFixtureLaunch.requestedTodosDesk() { return mode }
        #endif
        return environment.todoDeskModes.mode(for: deskKind)
    }

    /// A todo opened from the add sheet's note, once that sheet has left.
    private func openAdded(_ todoId: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            open(todoId)
        }
    }

    private func tickForFixture() {
        #if DEBUG
            // Once per launch: the home page can be built again once `/me` names it.
            guard PaiFixtureLaunch.ticksTodosRow(), !TodoFixtureOnce.ticked else { return }
            for case .todo(let id, _, _, _) in rows {
                TodoFixtureOnce.ticked = true
                tick(id)
                return
            }
        #endif
    }

    private func openFixtureState() {
        #if DEBUG
            if PaiFixtureLaunch.expandsTodosParent() { toggleExpanded(PaiFixtures.todosParent) }
            if PaiFixtureLaunch.opensTodosSheet() { open(PaiFixtures.todosParent) }
            if let text = PaiFixtureLaunch.requestedTodosAdd() { startAdding(.line, text: text) }
            if let text = PaiFixtureLaunch.requestedTodosDescribe() { startAdding(.describe, text: text) }
            if let query = PaiFixtureLaunch.requestedTodosSwitch() {
                switchQuery = query
                switching = true
            }
            if PaiFixtureLaunch.requestedTodosSettings() != nil { showsSettings = true }
        #endif
    }
}

/// Todos' views, lists and tags: the web's sidebar, as a screen. Each entry opens its page.
struct TodoBrowseScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showTags = false
    @State private var showsSettings = false

    private var browse: TodoBrowse {
        TodoBrowse.make(me: environment.todos.me, viewCounts: environment.todos.viewCounts)
    }

    var body: some View {
        List {
            section("Favourites", browse.favourites)
            if !browse.moreViews.isEmpty { section("More views", browse.moreViews) }
            section("Lists", browse.lists)
            if !browse.tags.isEmpty {
                if browse.tagsFolded && !showTags {
                    Button("Tags \(browse.tags.count)") { showTags = true }
                        .font(.footnote.weight(.semibold))
                } else {
                    section("Tags", browse.tags)
                }
            }
            Section {
                Button {
                    showsSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationDestination(isPresented: $showsSettings) { TodoSettingsScreen() }
        .navigationTitle("Views and lists")
        .navigationBarTitleDisplayMode(.inline)
        // Again after every change, made here or elsewhere, so no count is left behind.
        .task(id: environment.todos.readTick) { await environment.todos.refreshViewCounts() }
        .fixtureFact("todosBrowse", "\(browse.favourites.count),\(browse.moreViews.count),\(browse.lists.count)")
    }

    private func section(_ title: String, _ entries: [TodoBrowse.Entry]) -> some View {
        Section(title) {
            ForEach(entries) { entry in
                Button {
                    if let page = entry.page { environment.router.push(.todosPage(page)) }
                } label: {
                    HStack(spacing: 10) {
                        TodoIdentityIcon(identity: entry.identity)
                        Text(entry.title).foregroundStyle(PaiPalette.Semantic.textStrong)
                        if entry.locked {
                            Image(systemName: "lock").font(.caption).foregroundStyle(PaiPalette.Semantic.textFaint)
                        }
                        Spacer()
                        if let count = entry.count {
                            Text("\(count)").monospacedDigit().foregroundStyle(PaiPalette.Semantic.textFaint)
                        }
                    }
                }
            }
        }
    }
}

#if DEBUG
    /// What a fixture launch has done already, kept for the process rather than a page.
    @MainActor
    enum TodoFixtureOnce {
        static var ticked = false
    }
#endif
