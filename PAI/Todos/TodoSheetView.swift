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
    @State private var newSubtask = ""
    @State private var backdating = false
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let todo {
                    ToolbarItem(placement: .topBarLeading) { moreMenu(todo) }
                }
            }
            .sheet(isPresented: $backdating) {
                TodoDayPickerScreen(title: "Done on an earlier day", today: today, maxDate: today) { day in
                    if let day { submit([TodoFieldOps.doneOn(todoId, day: day)]) }
                    backdating = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .task(id: store.readTick) { await store.loadSheet(todoId) }
        .fixtureFact("todosSheet", todo?.ref ?? "")
    }

    private func submit(_ ops: [TodoOp]) {
        if let blocked {
            toasts.show(blocked, kind: .error)
            return
        }
        store.submit(ops)
    }

    @ViewBuilder private func content(_ todo: Todo) -> some View {
        List {
            statusBanner(todo)
            Section {
                titleRow(todo)
            }
            TodoFieldSections(todo: todo, today: today, canEdit: blocked == nil, submit: submit)
            subtasks(todo)
            description(todo)
            files(todo)
            links(todo)
            history
        }
        .listStyle(.insetGrouped)
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
                store.toggleDone(todoId: todo.id)
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
                Button("Drop it") { submit([TodoOp.complete(todo: todo.id, dropped: true)]) }
                if todo.repeat != nil { Button("Skip this time") { submit([TodoFieldOps.skip(todo.id)]) } }
            }
            if todo.status != .deleted && blocked == nil {
                Button("Delete", role: .destructive) {
                    submit([TodoFieldOps.delete(todo.id)])
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
                        store.toggleDone(todoId: child.id)
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
                TextField("Add a subtask", text: $newSubtask)
                    .submitLabel(.done)
                    .onSubmit(addSubtask)
            }
        }
    }

    private func childFromDetail(_ id: String) -> Todo? {
        store.details[todoId]?.children?.first { $0.id == id }
    }

    private func addSubtask() {
        let words = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        submit([TodoFieldOps.subtask(id: TodosStore.uuidv7(), parent: todoId, title: words)])
        newSubtask = ""
    }

    @ViewBuilder private func description(_ todo: Todo) -> some View {
        Section("Description") {
            NavigationLink {
                TodoDescriptionScreen(todo: todo, canEdit: blocked == nil, submit: submit)
            } label: {
                let text = store.details[todo.id]?.todo.body ?? todo.body ?? todo.bodyPreview
                Text(text.isEmpty ? "No description" : text)
                    .lineLimit(8)
                    .foregroundStyle(text.isEmpty ? PaiPalette.Semantic.textFaint : PaiPalette.Semantic.textPrimary)
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
    @State private var text = ""
    @State private var loaded = false

    private var current: String { environment.todos.details[todo.id]?.todo.body ?? todo.body ?? "" }

    var body: some View {
        TextEditor(text: $text)
            .padding(.horizontal, 12)
            .disabled(!canEdit)
            .navigationTitle("Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canEdit {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let hash = environment.todos.details[todo.id]?.todo.bodyHash ?? todo.bodyHash
                            if text != current { submit([TodoFieldOps.body(todo.id, text, ifBodyHash: hash)]) }
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                if !loaded {
                    text = current
                    loaded = true
                }
            }
    }
}
