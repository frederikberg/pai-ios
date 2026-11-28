import PAIKit
import SwiftUI

/// The one search, the web's search box: asked a moment after the last key, the answer kept on
/// screen until the next one arrives, words or the query language alike (`tag:home`, `is:done`).
/// It draws what the server sends: the direct hit, the ranked todos with what matched marked, the
/// corrections, the tags, views and lists to jump to, a row that adds the text as a todo and one
/// that keeps the search as a view.
/// The keyboard is up as the screen opens. Before anything is typed it shows how the box is used,
/// what was opened from search lately and the searches run often; what is opened from here is
/// told to the server, which keeps that list for every device.
struct TodoSearchScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @State private var text = ""
    @State private var searching = false
    @State private var showsHelp = false
    @State private var answer: TodosSearchAnswer?
    @State private var failed = false
    @State private var opened: TodoSheetTarget?
    /// The search being saved as a view, in the view's form.
    @State private var saving: TodoSearchSave?

    private var store: TodosStore { environment.todos }

    /// How long typing waits before the search is asked.
    private static let debounce: Duration = .milliseconds(70)

    var body: some View {
        List {
            if failed {
                Text("Search could not be reached.").foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if let answer {
                results(answer)
            }
        }
        .listStyle(.plain)
        .searchable(
            text: $text, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search or tag:home"
        )
        .sheet(isPresented: $showsHelp) { help }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: text) {
            if !text.isEmpty { try? await Task.sleep(for: Self.debounce) }
            guard !Task.isCancelled else { return }
            do {
                let next = try await store.search(TodosSearchRequest(q: text))
                guard !Task.isCancelled else { return }
                answer = next
                failed = false
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        // Asked for once the field is in the bar: a field presented with its first frame can
        // stay without the keyboard.
        .task { searching = true }
        .task { openFixtureSearch() }
        .sheet(item: $opened) { target in TodoSheetView(todoId: target.id) }
        .navigationDestination(item: $saving) { (search: TodoSearchSave) in
            TodoViewSettingsScreen(
                viewId: nil, search: search,
                onSaved: { (id: String, name: String) in viewSaved(id: id, name: name) })
        }
        .fixtureFact("todosSearchHits", String((answer?.todos.count ?? 0) + (answer?.top == nil ? 0 : 1)))
        .fixtureFact("todosSearchRecents", String(recents(answer).count))
    }

    @ViewBuilder private func results(_ answer: TodosSearchAnswer) -> some View {
        ForEach(answer.query.corrections, id: \.from) { correction in
            Text("Showing \(correction.to) for \(correction.from)")
                .font(.footnote)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        if let top = answer.top {
            Section("Top hit") { hitRow(top) }
        }
        if !answer.todos.isEmpty {
            Section("Todos \(answer.counts.open + answer.counts.closed)") {
                ForEach(answer.todos, id: \.todo.id) { hitRow($0) }
            }
        }
        if !answer.fewer.isEmpty {
            Section("With fewer of the words") {
                ForEach(answer.fewer, id: \.todo.id) { hitRow($0) }
            }
        }
        jumps(answer)
        ForEach(answer.offers.filter { $0.kind == "create" }, id: \.label) { offer in
            Button {
                add(offer.q ?? text)
            } label: {
                Label(offer.label, systemImage: "plus.circle")
            }
        }
        if let search = TodoSearchSave.proposal(answer, text: text) {
            Button {
                saving = search
            } label: {
                Label("Save this search as a view\u{2026}", systemImage: "bookmark")
            }
        }
        if text.isEmpty { zeroState(answer) }
    }

    /// Adds the words as a todo and says how that went, as the add sheet does: added with Undo,
    /// or why not. Words the server refused go back into the empty field.
    private func add(_ words: String) {
        let changeId: String = store.capture(text: words)
        text = ""
        Task {
            let outcome: TodosCaptureOutcome = await store.outcome(of: changeId, timeout: 4)
            switch outcome.settlement {
            case .applied:
                TodoUndoToast.show("Added · \(outcome.title)", changeId: changeId, store: store, toasts: toasts)
            case .refused:
                toasts.show(outcome.message(keeper: .app), kind: .error)
                if text.isEmpty { text = words }
            case .waiting:
                toasts.show(outcome.message(keeper: .app), kind: .info)
            }
        }
    }

    /// The view the search was saved as, one tap away.
    private func viewSaved(id: String, name: String) {
        let open = ToastMessage.Action(label: "Open") { [environment = self.environment] in
            environment.router.push(.todosPage(.view(id)))
        }
        toasts.show(
            "Saved the view \u{201C}\(name)\u{201D}", kind: .info, action: open,
            lifetimeNanos: TodoUndoToast.lifetimeNanos)
    }

    /// One line of the Recent section: something opened from search that can be named here.
    private struct RecentRow: Identifiable {
        let id: String
        let title: String
        let identity: TodoIdentity?
        let open: () -> Void
    }

    /// The recents this phone can name and open: a todo it holds, a view or a list the person
    /// still has, a tag, or a search to run again.
    private func recents(_ answer: TodosSearchAnswer?) -> [RecentRow] {
        let chosen = TodoIdentity.chosenTagColors(store.me?.tags ?? [])
        func tagColor(_ name: String) -> TodoColor { TodoIdentity.tagColor(name, chosen: chosen) }
        var rows: [RecentRow] = []
        for recent in answer?.recents ?? [] {
            let target = recent.target
            let id = "\(recent.kind?.rawValue ?? ""):\(target)"
            switch recent.kind {
            case .todo:
                guard let todo = store.todos[target] else { continue }
                rows.append(
                    RecentRow(id: id, title: todo.title, identity: nil) { opened = TodoSheetTarget(id: target) })
            case .view:
                guard let view = store.me?.views.first(where: { $0.id == target }) else { continue }
                rows.append(
                    RecentRow(id: id, title: view.name, identity: TodoIdentity.of(view: view, tagColor: tagColor)) {
                        environment.router.push(.todosPage(.view(target)))
                    })
            case .list:
                guard let list = store.lists.first(where: { $0.id == target }) else { continue }
                rows.append(
                    RecentRow(id: id, title: list.name, identity: TodoIdentity.of(list: list)) {
                        environment.router.push(.todosPage(.list(target)))
                    })
            case .tag:
                let name = recent.tagName
                guard !name.isEmpty else { continue }
                rows.append(
                    RecentRow(id: id, title: "#\(name)", identity: TodoIdentity(icon: .hash, color: tagColor(name))) {
                        environment.router.push(.todosPage(.tag(name)))
                    })
            case .query:
                rows.append(RecentRow(id: id, title: target, identity: nil) { text = target })
            case nil:
                continue
            }
        }
        return rows
    }

    /// Before anything is typed: how the box is used, what was opened lately, what is searched
    /// again and again.
    @ViewBuilder private func zeroState(_ answer: TodosSearchAnswer) -> some View {
        Button {
            showsHelp = true
        } label: {
            Label("What can I type here?", systemImage: "questionmark.circle")
        }
        let recent = recents(answer)
        if !recent.isEmpty {
            Section("Recent") {
                ForEach(recent) { row in
                    Button(action: row.open) {
                        HStack(spacing: 10) {
                            if let identity = row.identity {
                                TodoIdentityIcon(identity: identity)
                            } else {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                            }
                            Text(row.title).foregroundStyle(PaiPalette.Semantic.textStrong).lineLimit(1)
                        }
                    }
                }
            }
        }
        if let repeated = answer.repeated, !repeated.isEmpty {
            Section("You keep searching this") {
                ForEach(repeated, id: \.self) { query in
                    Button {
                        text = query
                    } label: {
                        Label(query, systemImage: "magnifyingglass")
                    }
                }
            }
        }
    }

    /// What the box takes, with the server's own examples to try.
    private var help: some View {
        NavigationStack {
            List {
                Section {
                    Text("Type words to find todos by what they say.")
                    Text("A filter such as tag:home narrows what is found.")
                    Text("Views, lists and tags that match are listed under Go to.")
                }
                if let examples = answer?.examples, !examples.isEmpty {
                    Section("Tap one to try it") {
                        ForEach(examples, id: \.self) { example in
                            Button(example) {
                                text = example
                                showsHelp = false
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { showsHelp = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func jumps(_ answer: TodosSearchAnswer) -> some View {
        let chosen = TodoIdentity.chosenTagColors(store.me?.tags ?? [])
        if !answer.tags.isEmpty || !answer.views.isEmpty || !answer.lists.isEmpty {
            Section("Go to") {
                ForEach(answer.views, id: \.view.id) { hit in
                    jumpRow(
                        hit.view.name,
                        TodoIdentity.of(view: hit.view, tagColor: { TodoIdentity.tagColor($0, chosen: chosen) }),
                        .view(hit.view.id))
                }
                ForEach(answer.lists, id: \.list.id) { hit in
                    jumpRow(hit.list.name, TodoIdentity.of(list: hit.list), .list(hit.list.id))
                }
                ForEach(answer.tags, id: \.tag.id) { hit in
                    jumpRow(
                        hit.tag.name,
                        TodoIdentity(icon: .hash, color: TodoIdentity.tagColor(hit.tag.name, chosen: chosen)),
                        .tag(hit.tag.name))
                }
            }
        }
    }

    private func jumpRow(_ title: String, _ identity: TodoIdentity, _ page: TodoPage) -> some View {
        Button {
            remember(page)
            environment.router.push(.todosPage(page))
        } label: {
            HStack(spacing: 10) {
                TodoIdentityIcon(identity: identity)
                Text(title).foregroundStyle(PaiPalette.Semantic.textStrong)
            }
        }
    }

    private func hitRow(_ hit: TodosSearchAnswer.Hit) -> some View {
        Button {
            store.remember(.todo, target: hit.todo.id)
            opened = TodoSheetTarget(id: hit.todo.id)
        } label: {
            TodoSearchHitLabel(hit: hit)
        }
        .buttonStyle(.plain)
    }

    /// A page opened from search, told to the server as the web tells it: a view or a list by
    /// its id, a tag by its list and name.
    private func remember(_ page: TodoPage) {
        switch page {
        case .view(let id): store.remember(.view, target: id)
        case .list(let id): store.remember(.list, target: id)
        case .tag(let name):
            guard let tag = store.me?.tags.first(where: { $0.name == name }) else { return }
            store.remember(.tag, target: "\(tag.listId):\(name)")
        }
    }

    /// Text with the matched runs in bold.
    static func marked(_ parts: [TodoTextPart]) -> Text {
        var string = AttributedString()
        for part in parts {
            var run = AttributedString(part.t)
            if part.m { run.inlinePresentationIntent = .stronglyEmphasized }
            string += run
        }
        return Text(string)
    }

    private func openFixtureSearch() {
        #if DEBUG
            if let q = PaiFixtureLaunch.requestedTodosSearch() { text = q }
        #endif
    }
}

/// A found todo: where it sits, its title with what matched in bold, and the matching text.
struct TodoSearchHitLabel: View {
    let hit: TodosSearchAnswer.Hit

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TodoTickCircle(mark: TodoHorizonMark.of(hit.todo.horizon), done: hit.todo.status != .open)
            VStack(alignment: .leading, spacing: 2) {
                if !hit.breadcrumb.isEmpty {
                    Text(hit.breadcrumb.joined(separator: " › "))
                        .font(.caption)
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                        .lineLimit(1)
                }
                TodoSearchScreen.marked(hit.titleParts).foregroundStyle(PaiPalette.Semantic.textStrong)
                if let snippet = hit.snippet {
                    TodoSearchScreen.marked(snippet.parts)
                        .font(.footnote)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
