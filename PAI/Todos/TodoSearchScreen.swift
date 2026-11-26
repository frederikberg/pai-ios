import PAIKit
import SwiftUI

/// The one search, the web's search box: asked a moment after the last key, the answer kept on
/// screen until the next one arrives, words or the query language alike (`tag:home`, `is:done`).
/// It draws what the server sends: the direct hit, the ranked todos with what matched marked, the
/// corrections, the tags, views and lists to jump to, and a row that adds the text as a todo.
struct TodoSearchScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var text = ""
    @State private var answer: TodosSearchAnswer?
    @State private var failed = false
    @State private var opened: TodoSheetTarget?

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
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or tag:home")
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
        .task { openFixtureSearch() }
        .sheet(item: $opened) { target in TodoSheetView(todoId: target.id) }
        .fixtureFact("todosSearchHits", String((answer?.todos.count ?? 0) + (answer?.top == nil ? 0 : 1)))
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
                store.capture(text: offer.q ?? text)
                text = ""
            } label: {
                Label(offer.label, systemImage: "plus.circle")
            }
        }
        if text.isEmpty, let examples = answer.examples, !examples.isEmpty {
            Section("Try") {
                ForEach(examples, id: \.self) { example in
                    Button(example) { text = example }
                }
            }
        }
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
            opened = TodoSheetTarget(id: hit.todo.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                TodoTickCircle(mark: TodoHorizonMark.of(hit.todo.horizon), done: hit.todo.status != .open)
                VStack(alignment: .leading, spacing: 2) {
                    if !hit.breadcrumb.isEmpty {
                        Text(hit.breadcrumb.joined(separator: " › "))
                            .font(.caption)
                            .foregroundStyle(PaiPalette.Semantic.textFaint)
                            .lineLimit(1)
                    }
                    Self.marked(hit.titleParts).foregroundStyle(PaiPalette.Semantic.textStrong)
                    if let snippet = hit.snippet {
                        Self.marked(snippet.parts)
                            .font(.footnote)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                            .lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
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
