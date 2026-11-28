import PAIKit
import SwiftUI

/// Picks the todo another one is moved under: the app's search, narrowed to open todos that can
/// take it. The keyboard is up as it opens; a tap on a hit is the choice.
struct TodoParentPicker: View {
    let todo: Todo
    let onPick: (Todo) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var searching = false
    @State private var answer: TodosSearchAnswer?
    /// The words `answer` was asked with.
    @State private var answered: String?
    @State private var failed = false

    private var store: TodosStore { environment.todos }

    private static let debounce: Duration = .milliseconds(70)

    private var hits: [TodosSearchAnswer.Hit] {
        guard let answer, !text.isEmpty else { return [] }
        var rows: [TodosSearchAnswer.Hit] = []
        if let top = answer.top { rows.append(top) }
        rows.append(contentsOf: answer.todos)
        rows.append(contentsOf: answer.fewer)
        var seen = Set<String>()
        var allowed: [TodosSearchAnswer.Hit] = []
        for hit in rows {
            guard TodoParentChoice.allowed(hit.todo, moving: todo, todos: store.todos, lists: store.lists) else {
                continue
            }
            if seen.insert(hit.todo.id).inserted { allowed.append(hit) }
        }
        return allowed
    }

    private var prompt: String { "Type to find the todo to put \u{201C}\(todo.title)\u{201D} under." }

    var body: some View {
        let hits = hits
        return NavigationStack {
            List {
                if failed {
                    Text("Search could not be reached.").foregroundStyle(PaiPalette.Semantic.textMuted)
                } else if text.isEmpty {
                    Text(prompt).foregroundStyle(PaiPalette.Semantic.textMuted)
                } else if answered == text, hits.isEmpty {
                    Text("No open todo found that it can go under.").foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                ForEach(hits, id: \.todo.id) { hit in
                    Button {
                        onPick(hit.todo)
                    } label: {
                        TodoSearchHitLabel(hit: hit)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $text, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search todos"
            )
            .navigationTitle("Move under")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task(id: text) { await search(text) }
            // Asked for once the field is in the bar: a field presented with its first frame can
            // stay without the keyboard.
            .task { searching = true }
            .task { openFixtureSearch() }
            .fixtureFact("todosParentHits", String(hits.count))
        }
    }

    private func openFixtureSearch() {
        #if DEBUG
            if let q = PaiFixtureLaunch.requestedTodosSearch() { text = q }
        #endif
    }

    private func search(_ words: String) async {
        guard !words.isEmpty else { return }
        try? await Task.sleep(for: Self.debounce)
        guard !Task.isCancelled else { return }
        do {
            let next = try await store.search(TodosSearchRequest(q: words, status: "open"))
            guard !Task.isCancelled else { return }
            answer = next
            answered = words
            failed = false
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
