import PAIKit
import SwiftUI

/// Go to a view, a list or a tag by typing a few letters: the keyboard is up at once, the best
/// match is first, and Return or a tap goes there. "Settings" is found the same way.
struct TodoSwitcherSheet: View {
    /// Where a pick goes: a page, or nil for Todos' settings.
    let onPick: (TodoPage?) -> Void
    var initialQuery = ""

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var hits: [TodoSwitcher.Hit] {
        let browse = TodoBrowse.make(me: environment.todos.me, viewCounts: environment.todos.viewCounts)
        return TodoSwitcher.hits(browse, query: query)
    }

    var body: some View {
        NavigationStack {
            List {
                if hits.isEmpty {
                    Text("Nothing is called that.").foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                    Button {
                        pick(hit)
                    } label: {
                        HStack(spacing: 10) {
                            TodoIdentityIcon(identity: hit.identity)
                            Text(hit.kind == .tag ? "#\(hit.title)" : hit.title)
                                .foregroundStyle(PaiPalette.Semantic.textStrong)
                            Spacer()
                            Text(kindWord(hit.kind)).font(.caption).foregroundStyle(PaiPalette.Semantic.textFaint)
                            if index == 0, !query.isEmpty {
                                Image(systemName: "return").font(.caption).foregroundStyle(
                                    PaiPalette.Semantic.textMuted)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                TextField("Go to a view, list or tag", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit { if let first = hits.first { pick(first) } }
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .background(PaiPalette.Semantic.panelBackground)
            }
            .navigationTitle("Go to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .task {
            if query.isEmpty { query = initialQuery }
            focused = true
        }
        .fixtureFact("todosSwitcherHits", String(hits.count))
        .fixtureFact("todosSwitcherFirst", hits.first?.title.replacingOccurrences(of: " ", with: "_") ?? "")
    }

    private func kindWord(_ kind: TodoSwitcher.Kind) -> String {
        switch kind {
        case .view: "View"
        case .list: "List"
        case .tag: "Tag"
        case .settings: "Todos"
        }
    }

    private func pick(_ hit: TodoSwitcher.Hit) {
        dismiss()
        onPick(hit.page)
    }
}
