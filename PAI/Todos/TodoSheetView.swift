import PAIKit
import SwiftUI

/// Which todo a sheet shows.
struct TodoSheetTarget: Identifiable, Hashable {
    let id: String
}

/// A todo opened from a row: the tick and the title, its fields (horizon, when with its time,
/// repeat and nudges, deadline, tags, list, desk), its subtasks, the description, its files and
/// links, and what changed lately. Every choice is one change through the outbox, drawn at once;
/// the sheet reads the todo again whenever a change took.
struct TodoSheetView: View {
    let todoId: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var backdating = false
    /// The When screen pushed without a tap, for a screenshot of the nudges.
    @State private var showsWhen = false
    @FocusState private var titleFocused: Bool

    private var store: TodosStore { environment.todos }

    private var todo: Todo? { store.todos[todoId] ?? store.details[todoId]?.todo ?? store.logbookTodos[todoId] }

    private var list: TodoList? { todo.flatMap { todo in store.lists.first { $0.id == todo.listId } } }

    /// Why this person may not change the todo's own fields, or nil when they may.
    private var blocked: String? { TodoPermissions.tickBlockedReason(list) }

    private var today: String { store.personsToday }

    private var chosenTags: [String: TodoColor] { TodoIdentity.chosenTagColors(store.me?.tags ?? []) }

    var body: some View {
        NavigationStack {
            Group {
                if let todo {
                    content(todo)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(todo?.ref ?? "Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // "Close", not "Done": in a todo app Done reads as finishing the todo.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if let todo {
                    ToolbarItem(placement: .topBarTrailing) { moreMenu(todo) }
                }
            }
            .navigationDestination(isPresented: $showsWhen) {
                if let todo {
                    TodoWhenScreen(todo: todo, today: today, canEdit: blocked == nil, submit: submit)
                }
            }
            .sheet(isPresented: $backdating) {
                TodoDayPickerScreen(title: "Done on an earlier day", today: today, maxDate: today) { day in
                    if let day {
                        undoable(
                            [TodoFieldOps.doneOn(todoId, day: day)],
                            "Completed \u{201C}\(todo?.title ?? "")\u{201D} on \(day)")
                    }
                    backdating = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .task(id: store.readTick) { await store.loadSheet(todoId) }
        .task {
            #if DEBUG
                if PaiFixtureLaunch.opensTodosWhen() { showsWhen = true }
            #endif
        }
        .fixtureFact("todosSheet", todo?.ref ?? "")
    }

    /// A change that takes something away, said with Undo.
    private func undoable(_ ops: [TodoOp], _ text: String) {
        if let blocked {
            toasts.show(blocked, kind: .error)
            return
        }
        TodoUndoToast.show(text, changeId: store.submit(ops), store: store, toasts: toasts)
    }

    private func submit(_ ops: [TodoOp]) {
        if let blocked {
            toasts.show(blocked, kind: .error)
            return
        }
        store.submit(ops)
    }

    @ViewBuilder private func content(_ todo: Todo) -> some View {
        ScrollViewReader { proxy in
            sheetList(todo).task { await scrollToSubtasksForFixture(proxy) }
        }
    }

    private static let subtasksAnchor = "subtasks"

    /// A fixture launch with a subtask line photographs that line, below the fields.
    private func scrollToSubtasksForFixture(_ proxy: ScrollViewProxy) async {
        #if DEBUG
            guard PaiFixtureLaunch.requestedTodosSubtask() != nil else { return }
            try? await Task.sleep(for: .milliseconds(600))
            proxy.scrollTo(Self.subtasksAnchor, anchor: .top)
        #endif
    }

    @ViewBuilder private func sheetList(_ todo: Todo) -> some View {
        List {
            statusBanner(todo)
            Section {
                titleRow(todo)
            }
            // Right under the title, so what was written about the todo is read without scrolling
            // past its seven field rows.
            description(todo)
            TodoFieldSections(todo: todo, today: today, canEdit: blocked == nil, submit: submit)
            subtasks(todo).id(Self.subtasksAnchor)
            files(todo)
            links(todo)
            history
        }
        .listStyle(.insetGrouped)
        // Reported by the list, which builds every time, not by the row, which a lazy list may not.
        .fixtureFact("todosDescriptionBlocks", String(descriptionBlocks(todo)))
    }

    private func descriptionBlocks(_ todo: Todo) -> Int {
        let text = store.details[todo.id]?.todo.body ?? todo.body ?? ""
        return text.isEmpty ? 0 : NotePreviewDocument(body: text, nameToId: [:]).items.count
    }

    @ViewBuilder private func statusBanner(_ todo: Todo) -> some View {
        switch todo.status {
        case .deleted:
            Section {
                HStack {
                    Text("This todo is deleted.")
                    Spacer()
                    if blocked == nil { Button("Restore") { submit([TodoFieldOps.restore(todo.id)]) } }
                }
                .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        case .done, .dropped:
            Section {
                Text(todo.status == .done ? "Completed." : "Dropped.").foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        case .open, .unrecognized:
            EmptyView()
        }
    }

    private func titleRow(_ todo: Todo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if let blocked {
                    toasts.show(blocked, kind: .error)
                    return
                }
                TodoUndoToast.toggleDone(todo, store: store, toasts: toasts)
            } label: {
                TodoTickCircle(mark: TodoHorizonMark.of(todo.horizon), done: todo.status != .open, size: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.status == .open ? "Complete" : "Reopen")
            TextField("Title", text: $title, axis: .vertical)
                .font(.title3.weight(.semibold))
                .focused($titleFocused)
                .disabled(blocked != nil || todo.status == .deleted)
                .submitLabel(.done)
                .onSubmit { titleFocused = false }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle(todo) } }
        }
        .onAppear { title = todo.title }
        .onChange(of: todo.title) { _, newTitle in if !titleFocused { title = newTitle } }
    }

    private func commitTitle(_ todo: Todo) {
        guard title != todo.title, let op = TodoFieldOps.title(todo.id, title.replacingOccurrences(of: "\n", with: " "))
        else {
            title = todo.title
            return
        }
        submit([op])
    }

    private func moreMenu(_ todo: Todo) -> some View {
        Menu {
            if let number = todo.number, let link = URL(string: "\(environment.backendURL)/apps/todos/t/\(number)") {
                ShareLink("Share link", item: link)
            }
            if todo.status == .open && blocked == nil {
                Button("Done on an earlier day…") { backdating = true }
                Button("Drop it") {
                    undoable(
                        [TodoOp.complete(todo: todo.id, dropped: true)], "Dropped \u{201C}\(todo.title)\u{201D}")
                }
                if todo.repeat != nil {
                    Button("Skip this time") {
                        undoable([TodoFieldOps.skip(todo.id)], "Skipped this round of \u{201C}\(todo.title)\u{201D}")
                    }
                }
            }
            if todo.status != .deleted && blocked == nil {
                // The sheet closes on a deleted todo, so the toast with Undo is the way back.
                Button("Delete", role: .destructive) {
                    undoable([TodoFieldOps.delete(todo.id)], "Deleted \u{201C}\(todo.title)\u{201D}")
                    dismiss()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More actions")
    }

    @ViewBuilder private func subtasks(_ todo: Todo) -> some View {
        let children = store.sheetChildren(of: todo.id).compactMap { store.todos[$0] ?? childFromDetail($0) }
        Section("Subtasks") {
            ForEach(children) { child in
                HStack(spacing: 10) {
                    Button {
                        if let blocked {
                            toasts.show(blocked, kind: .error)
                            return
                        }
                        TodoUndoToast.toggleDone(child, store: store, toasts: toasts)
                    } label: {
                        TodoTickCircle(mark: TodoHorizonMark.of(child.horizon), done: child.status != .open)
                    }
                    .buttonStyle(.plain)
                    Text(child.title)
                        .strikethrough(child.status != .open)
                        .foregroundStyle(
                            child.status == .open ? PaiPalette.Semantic.textStrong : PaiPalette.Semantic.textFaint)
                }
            }
            if blocked == nil && todo.status == .open {
                TodoSubtaskLine(parentId: todo.id, today: today)
            }
        }
    }

    private func childFromDetail(_ id: String) -> Todo? {
        store.details[todoId]?.children?.first { $0.id == id }
    }

    @ViewBuilder private func description(_ todo: Todo) -> some View {
        Section("Description") {
            NavigationLink {
                TodoDescriptionScreen(todo: todo, canEdit: blocked == nil, submit: submit)
            } label: {
                let text = store.details[todo.id]?.todo.body ?? todo.body ?? todo.bodyPreview
                if text.isEmpty {
                    Text("No description").foregroundStyle(PaiPalette.Semantic.textFaint)
                } else {
                    TodoDescriptionView(text: text)
                }
            }
        }
    }

    @ViewBuilder private func files(_ todo: Todo) -> some View {
        if !todo.attachments.isEmpty {
            Section("Files") {
                ForEach(todo.attachments, id: \.id) { file in
                    Label(file.name, systemImage: file.contentType.hasPrefix("image/") ? "photo" : "doc")
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private func links(_ todo: Todo) -> some View {
        if !todo.links.isEmpty {
            Section("Links") {
                ForEach(todo.links, id: \.id) { link in
                    if let url = absolute(link.url) {
                        Link(destination: url) { linkLabel(link) }
                    } else {
                        linkLabel(link)
                    }
                }
            }
        }
    }

    private func linkLabel(_ link: TodoLink) -> some View {
        Label(link.label ?? link.target, systemImage: "link").lineLimit(1)
    }

    private func absolute(_ url: String) -> URL? {
        url.hasPrefix("/") ? URL(string: environment.backendURL + url) : URL(string: url)
    }

    @ViewBuilder private var history: some View {
        if let changes = store.details[todoId]?.history, !changes.isEmpty {
            Section("Changes") {
                ForEach(changes, id: \.id) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.summary).font(.subheadline)
                        Text(Self.changeLine(change))
                            .font(.caption)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
            }
        }
    }

    private static func changeLine(_ change: TodoChange) -> String {
        let when = IsoTimestamp.date(from: change.createdAt).map {
            $0.formatted(.dateTime.day().month(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())
        }
        return [change.actor.label, when].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The description, read; Edit writes it whole, saved only if nobody changed it meanwhile.
struct TodoDescriptionScreen: View {
    let todo: Todo
    let canEdit: Bool
    let submit: ([TodoOp]) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// Begun once the whole description has been read; saved by Save and again on leaving.
    @State private var edit: TodoBodyEdit?

    /// The todo as last read whole; a row carries only the first line of its description.
    private var read: Todo? {
        environment.todos.details[todo.id]?.todo ?? (todo.body != nil ? todo : nil)
    }

    var body: some View {
        Group {
            if let edit {
                TextEditor(text: Binding(get: { edit.text }, set: { self.edit?.text = $0 }))
                    .padding(.horizontal, 12)
                    .disabled(!canEdit)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Description")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        .onAppear(perform: begin)
        .onChange(of: read?.bodyHash) { begin() }
        // Leaving by Back or a swipe keeps what was typed, as Save would.
        .onDisappear(perform: save)
    }

    private func begin() {
        guard edit == nil, let read else { return }
        edit = TodoBodyEdit(read)
    }

    private func save() {
        guard canEdit, let op = edit?.take() else { return }
        submit([op])
    }
}

/// A todo's description as the Notes preview draws markdown: headings, lists and task boxes,
/// links and code. Its files are named; they open from the Files section.
struct TodoDescriptionView: View {
    let text: String

    /// A description longer than this many blocks is read on its own screen.
    static let blocksShown = 12

    var body: some View {
        let document = NotePreviewDocument(body: text, nameToId: [:])
        VStack(alignment: .leading, spacing: 8) {
            ForEach(document.items.prefix(Self.blocksShown)) { item in
                NotePreviewBlockView(
                    block: item.block, taskBase: item.firstTask, attachments: document.attachments, containerId: nil)
            }
            if document.items.count > Self.blocksShown {
                Text("More…").font(.footnote).foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .environment(\.previewNamesFilesOnly, true)
    }
}
