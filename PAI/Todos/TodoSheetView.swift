import PAIKit
import SwiftUI

/// Which todo a sheet shows.
struct TodoSheetTarget: Identifiable, Hashable {
    let id: String
}

/// A todo opened from a row. Its screen starts with the block the add sheet is made of (the tick
/// and the title, the description, the chips of what is set, the rail of field icons), then what
/// only an existing todo has: subtasks, files, links and what changed lately. A subtask opens as
/// a todo of its own inside the same sheet, and Back returns to its parent.
struct TodoSheetView: View {
    let todoId: String
    /// The defaults of the view the todo was opened from, which a subtask added here gets too.
    var viewDefaults: TodoViewDefaults?

    @Environment(\.dismiss) private var dismiss
    @State private var path: [TodoSheetTarget] = []

    var body: some View {
        NavigationStack(path: $path) {
            TodoScreen(todoId: todoId, viewDefaults: viewDefaults, parentTitle: nil, open: open, close: { dismiss() })
                .navigationDestination(for: TodoSheetTarget.self) { target in
                    // A subtask's own subtasks are not in the view's answer, so they get none of
                    // its defaults.
                    TodoScreen(
                        todoId: target.id, viewDefaults: nil, parentTitle: parentTitle(of: target.id), open: open)
                }
        }
    }

    @Environment(AppEnvironment.self) private var environment

    private func open(_ id: String) { path.append(TodoSheetTarget(id: id)) }

    private func parentTitle(of id: String) -> String? {
        let store = environment.todos
        return store.todos[id]?.parentId.flatMap { store.todos[$0]?.title }
    }
}

/// One todo's screen inside the sheet.
struct TodoScreen: View {
    let todoId: String
    let viewDefaults: TodoViewDefaults?
    /// Set on a subtask: the title of the todo it belongs to.
    let parentTitle: String?
    /// Opens a subtask.
    let open: (String) -> Void
    /// Closes the sheet; nil on a pushed subtask, which has Back.
    var close: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var titleFocused = false
    @State private var picker: TodoPicker?
    @State private var pickerStep: TodoPickerPanel.Step?
    @State private var backdating = false
    @State private var addingSubtask = false
    @State private var subtaskLine: String?
    @State private var editingDescription = false
    @State private var pickingPhoto = false
    @State private var pickingFile = false
    @State private var preview: FilePreviewTarget?
    @State private var showsAllChanges = false

    private var store: TodosStore { environment.todos }

    private var todo: Todo? { store.todos[todoId] ?? store.details[todoId]?.todo ?? store.logbookTodos[todoId] }

    private var list: TodoList? { todo.flatMap { todo in store.lists.first { $0.id == todo.listId } } }

    /// Why this person may not change the todo's own fields, or nil when they may.
    private var blocked: String? { TodoPermissions.tickBlockedReason(list) }

    private var today: String { store.personsToday }

    var body: some View {
        Group {
            if let todo {
                content(todo)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PaiPalette.Semantic.screenBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let close {
                // "Close", not "Done": in a todo app Done reads as finishing the todo.
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) }
            }
            ToolbarItem(placement: .principal) { heading }
            ToolbarItem(placement: .topBarTrailing) {
                if titleFocused {
                    Button("Done") { titleFocused = false }.fontWeight(.semibold)
                } else if let todo {
                    moreMenu(todo)
                }
            }
        }
        .sheet(item: $picker) { picker in
            if let todo {
                TodoPickerPanel(picker: picker, editing: editing(todo), startsAt: pickerStep) { self.picker = nil }
                    .padding(.top, 8)
                    .presentationDetents([.height(TodoKeyboard.shared.lastHeight + 40), .large])
                    .presentationBackground(PaiPalette.Semantic.panelBackground)
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
        .fullScreenCover(isPresented: $addingSubtask) {
            if let todo {
                TodoAddSheet(
                    todos: store,
                    draft: TodoCaptureDraft { [client = environment.connection?.apiClient] text in
                        guard let client else { throw PaiError.transport("Not signed in") }
                        return try await client.todosParse(text: text, list: nil, source: .ios)
                    },
                    place: .under(parent: todo.id, viewDefaults: viewDefaults), parent: todo, initialText: subtaskLine)
            }
        }
        .sheet(isPresented: $pickingPhoto) { PhotoAttachmentPicker(onPicked: attach) }
        .sheet(isPresented: $pickingFile) { FileAttachmentPicker(onPicked: attach) }
        .navigationDestination(isPresented: $editingDescription) {
            if let todo { TodoDescriptionScreen(todo: todo, canEdit: blocked == nil, store: store) }
        }
        .filePreview($preview)
        .task(id: store.readTick) { await store.loadSheet(todoId) }
        .task { openFixtureState() }
        .fixtureFact("todosSheet", todo?.ref ?? "")
    }

    private var heading: some View {
        VStack(spacing: 0) {
            Text(todo?.ref ?? "Todo").font(.headline)
            if let parentTitle {
                Text("in \(parentTitle)").font(.caption).foregroundStyle(PaiPalette.Semantic.textMuted).lineLimit(1)
            }
        }
    }

    private func openFixtureState() {
        #if DEBUG
            // Only the todo the launch opens, not a subtask pushed inside it.
            guard close != nil else { return }
            if PaiFixtureLaunch.opensTodosWhen() {
                pickerStep = .nudge
                picker = .when
            } else if let name = PaiFixtureLaunch.requestedTodosPicker() {
                picker = TodoPicker(rawValue: name)
            }
            if let line = PaiFixtureLaunch.requestedTodosSubtask() {
                subtaskLine = line
                addingSubtask = true
            }
        #endif
    }

    // MARK: - Changes

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

    /// What the pickers change on an existing todo: each choice is one change, drawn at once.
    private func editing(_ todo: Todo) -> TodoFieldEditing {
        let id = todo.id
        let nudges = store.nudges(of: id)
        return TodoFieldEditing(
            values: TodoEntryValues(todo: todo, nudges: nudges), today: today,
            canEdit: blocked == nil && todo.status != .deleted, canMove: todo.parentId == nil,
            setWhen: { when in submit([TodoFieldOps.when(id, date: when?.date, time: when?.time)]) },
            setSomeday: { submit([TodoFieldOps.someday(id, $0)]) },
            setRepeat: { submit([TodoFieldOps.repeat(id, $0)]) },
            setDeadline: { deadline in
                submit([TodoFieldOps.deadline(id, date: deadline?.date, leadDays: deadline?.leadDays)])
            },
            setHorizon: { horizon in if horizon != todo.horizon { submit([TodoFieldOps.horizon(id, horizon)]) } },
            setTag: { name, on in
                submit([on ? TodoFieldOps.tag(id, add: [name]) : TodoFieldOps.tag(id, remove: [name])])
            },
            setList: { submit([TodoFieldOps.move(id, toList: $0)]) },
            // The desk is the person's own: open to them whatever the list allows.
            setDesk: { on in
                if on {
                    store.submit([.deskAdd(todo: id, position: .first)])
                } else {
                    store.setOnDesk(todoId: id, false)
                }
            },
            addNudge: { store.submit([TodoFieldOps.nudgeSet(id, $0, id: TodosStore.uuidv7())]) },
            removeNudge: { store.submit([TodoFieldOps.nudgeRemove($0)]) },
            snoozeNudge: { store.submit([TodoFieldOps.nudgeSnooze($0, minutes: 60)]) },
            useDefaultNudges: TodoFieldOps.offersDefaults(todo, prefs: store.me?.prefs)
                ? { store.submit([TodoFieldOps.nudgeDefaults(id)]) } : nil)
    }

    // MARK: - The screen

    private func content(_ todo: Todo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusBanner(todo)
                block(todo)
                subtasks(todo)
                files(todo)
                links(todo)
                history
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .fixtureFact("todosDescriptionBlocks", String(descriptionBlocks(todo)))
        .fixtureFact("todosSubtasks", String(children(of: todo).count))
    }

    private func descriptionText(_ todo: Todo) -> String {
        store.details[todo.id]?.todo.body ?? todo.body ?? todo.bodyPreview
    }

    private func descriptionBlocks(_ todo: Todo) -> Int {
        let text = store.details[todo.id]?.todo.body ?? todo.body ?? ""
        return text.isEmpty ? 0 : NotePreviewDocument(body: text, nameToId: [:]).items.count
    }

    @ViewBuilder private func statusBanner(_ todo: Todo) -> some View {
        switch todo.status {
        case .deleted:
            HStack {
                Text("This todo is deleted.")
                Spacer()
                if blocked == nil { Button("Restore") { submit([TodoFieldOps.restore(todo.id)]) } }
            }
            .font(.subheadline)
            .foregroundStyle(PaiPalette.Semantic.errorText)
            .padding(.horizontal, 4)
        case .done, .dropped:
            Text(todo.status == .done ? "Completed." : "Dropped.")
                .font(.subheadline)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .padding(.horizontal, 4)
        case .open, .unrecognized:
            EmptyView()
        }
    }

    /// The add sheet's block, holding this todo.
    private func block(_ todo: Todo) -> some View {
        let fields = editing(todo)
        let chips = TodoAddChip.fields(fields.values, today: today, listName: nil).filter { $0.kind != "desk" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    if let blocked {
                        toasts.show(blocked, kind: .error)
                        return
                    }
                    TodoUndoToast.toggleDone(todo, store: store, toasts: toasts)
                } label: {
                    TodoTickCircle(
                        mark: TodoHorizonMark.of(todo.horizon), done: todo.status != .open, onDesk: todo.onDesk,
                        size: 26
                    )
                    .padding(.top, 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(todo.status == .open ? "Complete" : "Reopen")
                TodoTitleField(
                    text: $title, placeholder: "Title", dimmed: TodoTitles.overflow(of: title),
                    isFocused: titleFocused, isEditable: fields.canEdit, maxLines: 8, returnKey: .done,
                    onFocusChange: { focused in
                        if titleFocused != focused { titleFocused = focused }
                        if !focused { commitTitle(todo) }
                    },
                    onReturn: { titleFocused = false },
                    onPasteImages: { images in
                        attach(
                            images.map {
                                AttachmentCompression.stage(data: $0.data, filename: $0.filename, mimeType: $0.mimeType)
                            })
                    })
            }
            Button {
                leaveTitle()
                editingDescription = true
            } label: {
                description(todo)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 36)
            TodoFieldChips(chips: chips, tagColor: tagColor) { chip in
                if let next = TodoPicker.of(chipKind: chip.kind) { openPicker(next) }
            }
            .padding(.leading, 36)
            TodoFieldRail(
                editing: fields, open: picker, onPick: openPicker,
                onPhoto: fields.canEdit ? { pickingPhoto = true } : nil,
                onFile: fields.canEdit ? { pickingFile = true } : nil
            ) {
                if titleFocused {
                    TodoRailButton(systemImage: "keyboard.chevron.compact.down", label: "Hide keyboard") {
                        titleFocused = false
                    }
                }
            }
            .padding(.leading, 26)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(PaiPalette.Semantic.panelBackground))
        .overlay {
            if titleFocused { RoundedRectangle(cornerRadius: 16).strokeBorder(PaiPalette.primary500, lineWidth: 1.5) }
        }
        .onAppear { title = todo.title }
        .onChange(of: todo.title) { _, newTitle in if !titleFocused { title = newTitle } }
    }

    @ViewBuilder private func description(_ todo: Todo) -> some View {
        let text = descriptionText(todo)
        if text.isEmpty {
            Label("Description", systemImage: "text.alignleft")
                .font(.subheadline)
                .foregroundStyle(PaiPalette.Semantic.textFaint)
        } else {
            TodoDescriptionView(text: text).allowsHitTesting(false)
        }
    }

    private func tagColor(_ name: String) -> TodoColor {
        TodoIdentity.tagColor(name, chosen: TodoIdentity.chosenTagColors(store.me?.tags ?? []))
    }

    /// A tap on a field while the title is being typed: the title is saved, the keyboard goes
    /// and the picker rises.
    private func openPicker(_ next: TodoPicker) {
        leaveTitle()
        pickerStep = nil
        picker = next
    }

    private func leaveTitle() {
        guard titleFocused else { return }
        titleFocused = false
        TodoKeyboard.dismiss()
    }

    /// Saves a changed title. However long it is, it goes out whole: the server keeps what fits
    /// and puts the rest on top of the description.
    private func commitTitle(_ todo: Todo) {
        guard title != todo.title, let op = TodoFieldOps.title(todo.id, title) else {
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
                // The screen leaves a deleted todo, so the toast with Undo is the way back.
                Button("Delete", role: .destructive) {
                    undoable([TodoFieldOps.delete(todo.id)], "Deleted \u{201C}\(todo.title)\u{201D}")
                    if let close { close() } else { dismiss() }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More actions")
    }

    // MARK: - Subtasks

    private func children(of todo: Todo) -> [Todo] {
        store.sheetChildren(of: todo.id)
            .compactMap { id in store.todos[id] ?? store.details[todoId]?.children?.first { $0.id == id } }
            .filter { $0.status != .deleted }
    }

    private func canAddSubtask(_ todo: Todo) -> Bool { blocked == nil && todo.status == .open }

    @ViewBuilder private func subtasks(_ todo: Todo) -> some View {
        let rows = children(of: todo)
        let adds = canAddSubtask(todo)
        if !rows.isEmpty || adds {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeading(
                    "Subtasks", count: "\(rows.filter { $0.status != .open }.count)/\(rows.count)",
                    add: adds ? { startSubtask() } : nil)
                VStack(spacing: 0) {
                    ForEach(rows) { child in
                        subtaskRow(child)
                        Divider().padding(.leading, 44)
                    }
                    if adds {
                        Button(action: startSubtask) {
                            Label("Add subtask", systemImage: "plus")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 46)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PaiPalette.primary500)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(PaiPalette.Semantic.panelBackground))
            }
        }
    }

    private func startSubtask() {
        leaveTitle()
        subtaskLine = nil
        addingSubtask = true
    }

    private func subtaskRow(_ child: Todo) -> some View {
        HStack(spacing: 10) {
            Button {
                if let blocked {
                    toasts.show(blocked, kind: .error)
                    return
                }
                TodoUndoToast.toggleDone(child, store: store, toasts: toasts)
            } label: {
                TodoTickCircle(
                    mark: TodoHorizonMark.of(child.horizon), done: child.status != .open, onDesk: child.onDesk)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(child.status == .open ? "Complete \(child.title)" : "Reopen \(child.title)")
            Button {
                open(child.id)
            } label: {
                HStack(spacing: 8) {
                    Text(child.title)
                        .font(.body)
                        .strikethrough(child.status != .open)
                        .foregroundStyle(
                            child.status == .open ? PaiPalette.Semantic.textStrong : PaiPalette.Semantic.textFaint
                        )
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if child.childrenTotal > 0 {
                        Text("\(child.childrenTotal - child.childrenOpen)/\(child.childrenTotal)")
                            .font(.footnote).monospacedDigit().foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    if let day = TodoDates.dayMark(child.when, today: today, clock: store.personsClock) {
                        Text(day.label).font(.footnote).foregroundStyle(TodoRowView.lightColor(day.light))
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(PaiPalette.Semantic.textFaint)
                }
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .opacity(store.pendingIds.contains(child.id) ? 0.75 : 1)
    }

    private func sectionHeading(_ title: String, count: String?, add: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold))
            if let count { Text(count).font(.caption).monospacedDigit() }
            Spacer()
            if let add {
                Button(action: add) { Label("Add", systemImage: "plus").font(.caption.weight(.semibold)) }
                    .foregroundStyle(PaiPalette.primary500)
                    .accessibilityLabel("Add to \(title.lowercased())")
            }
        }
        .foregroundStyle(PaiPalette.Semantic.textMuted)
        .padding(.horizontal, 12)
    }

    // MARK: - Files, links, changes

    /// Picked, pasted or dropped: each becomes a file of this todo.
    private func attach(_ staged: [StagedAttachment]) {
        if let blocked {
            toasts.show(blocked, kind: .error)
            return
        }
        for file in staged {
            if store.attach(todoId: todoId, name: file.filename, contentType: file.mimeType, data: file.data) == nil {
                toasts.show("Could not keep \u{201C}\(file.filename)\u{201D} on this iPhone to send it.", kind: .error)
            }
        }
    }

    @ViewBuilder private func files(_ todo: Todo) -> some View {
        let queued = store.queuedFiles(of: todo.id)
        // The todo as its screen last read it: a row from a list may be older than its files.
        let attached = store.details[todo.id]?.todo.attachments ?? todo.attachments
        let adds = blocked == nil && todo.status != .deleted
        if !attached.isEmpty || !queued.isEmpty || adds {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeading("Files", count: String(attached.count + queued.count), add: nil)
                VStack(spacing: 0) {
                    ForEach(attached, id: \.id) { file in
                        Button {
                            openFile(file)
                        } label: {
                            fileRow(
                                name: file.name, image: file.contentType.hasPrefix("image/"), note: Self.size(file.size)
                            )
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 44)
                    }
                    ForEach(queued) { file in
                        fileRow(name: file.name, image: file.contentType.hasPrefix("image/"), note: "Sending…")
                            .opacity(0.75)
                        Divider().padding(.leading, 44)
                    }
                    if adds {
                        Menu {
                            Button("Photo", systemImage: "photo") { pickingPhoto = true }
                            Button("File", systemImage: "doc") { pickingFile = true }
                        } label: {
                            Label("Add a file or photo", systemImage: "plus")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 46)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(PaiPalette.Semantic.panelBackground))
            }
            .fixtureFact("todosFiles", String(attached.count))
        }
    }

    private func fileRow(name: String, image: Bool, note: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: image ? "photo" : "paperclip").frame(width: 20)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Text(name).font(.body).lineLimit(1).foregroundStyle(PaiPalette.Semantic.textStrong)
            Spacer(minLength: 4)
            Text(note).font(.footnote).foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Fetches a file and shows it; a kind with no preview offers to share it on.
    private func openFile(_ file: TodoAttachment) {
        guard let client = environment.connection?.apiClient else { return }
        Task {
            do {
                let data = try await client.todosAttachment(id: file.id)
                let kind: AttachmentPreviewKind? =
                    file.contentType.hasPrefix("image/") ? .image : (file.contentType == "application/pdf" ? .pdf : nil)
                preview = FilePreviewTarget(data: data, filename: file.name, kind: kind)
            } catch {
                toasts.show("Could not open \u{201C}\(file.name)\u{201D}.", kind: .error)
            }
        }
    }

    @ViewBuilder private func links(_ todo: Todo) -> some View {
        if !todo.links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeading("Links", count: nil, add: nil)
                VStack(spacing: 0) {
                    ForEach(todo.links, id: \.id) { link in
                        Group {
                            if let url = absolute(link.url) {
                                Link(destination: url) { linkLabel(link) }
                            } else {
                                linkLabel(link)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
                        Divider().padding(.leading, 44)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(PaiPalette.Semantic.panelBackground))
            }
        }
    }

    private func linkLabel(_ link: TodoLink) -> some View {
        Label(link.label ?? link.target, systemImage: "link")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func absolute(_ url: String) -> URL? {
        url.hasPrefix("/") ? URL(string: environment.backendURL + url) : URL(string: url)
    }

    /// How many changes show before the rest is asked for.
    private static let changesShown = 3

    @ViewBuilder private var history: some View {
        if let changes = store.details[todoId]?.history, !changes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    showsAllChanges.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("HISTORY").font(.caption.weight(.semibold))
                        Text("\(changes.count)").font(.caption).monospacedDigit()
                        Spacer()
                        if changes.count > Self.changesShown {
                            Image(systemName: showsAllChanges ? "chevron.up" : "chevron.down").font(.caption)
                        }
                    }
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsAllChanges ? "Show fewer changes" : "Show all \(changes.count) changes")
                VStack(spacing: 0) {
                    ForEach(changes.prefix(showsAllChanges ? changes.count : Self.changesShown), id: \.id) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath").font(.footnote)
                                .foregroundStyle(PaiPalette.Semantic.textFaint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.summary).font(.subheadline)
                                Text(Self.changeLine(change))
                                    .font(.caption)
                                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        Divider().padding(.leading, 44)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(PaiPalette.Semantic.panelBackground))
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
