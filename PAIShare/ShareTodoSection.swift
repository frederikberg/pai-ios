import PAIKit
import SwiftUI

/// "Todo" in the share sheet: the shared text (or the link) as a todo's words, editable, with
/// the link attached. What the server's parser reads in the words applies, as in the app. A todo
/// the server did not take stays here with its words and a Try again; nothing waits elsewhere.
struct ShareTodoSection: View {
    @Bindable var todo: ShareTodoStore
    let close: () -> Void

    var body: some View {
        Section("Todo") {
            if case .added(let outcome) = todo.phase {
                Label(outcome.message(keeper: .shareSheet), systemImage: "checkmark.circle")
                    .task {
                        try? await Task.sleep(for: .seconds(1.2))
                        close()
                    }
            } else {
                TextField(
                    todo.link == nil ? "New todo" : "New todo (the link is attached)", text: $todo.text, axis: .vertical
                )
                .lineLimit(1...4)
                if let link = todo.link {
                    Label(link, systemImage: "link").font(.footnote).lineLimit(1).truncationMode(.middle)
                }
                if case .notAdded(let outcome) = todo.phase {
                    Text(outcome.message(keeper: .shareSheet)).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await todo.add() }
                } label: {
                    if todo.phase == .sending {
                        ProgressView()
                    } else if case .notAdded = todo.phase {
                        Label("Try again", systemImage: "arrow.clockwise")
                    } else {
                        Label("Add as todo", systemImage: "checkmark.circle")
                    }
                }
                .disabled(!todo.canAdd)
            }
        }
    }
}
