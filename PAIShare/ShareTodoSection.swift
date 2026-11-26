import PAIKit
import SwiftUI

/// "Todo" in the share sheet: the shared text (or the link) as a todo's words, editable, with
/// the link attached. What the server's parser reads in the words applies, as in the app.
struct ShareTodoSection: View {
    @Bindable var todo: ShareTodoStore
    let close: () -> Void

    var body: some View {
        Section("Todo") {
            switch todo.phase {
            case .editing, .sending:
                TextField(
                    todo.link == nil ? "New todo" : "New todo (the link is attached)", text: $todo.text, axis: .vertical
                )
                .lineLimit(1...4)
                if let link = todo.link {
                    Label(link, systemImage: "link").font(.footnote).lineLimit(1).truncationMode(.middle)
                }
                Button {
                    Task { await todo.add() }
                } label: {
                    if todo.phase == .sending {
                        ProgressView()
                    } else {
                        Label("Add as todo", systemImage: "checkmark.circle")
                    }
                }
                .disabled(!todo.canAdd)
            case .done(let outcome):
                Label(outcome.message(keeper: .shareSheet), systemImage: outcome.added ? "checkmark.circle" : "clock")
                    .task {
                        guard outcome.added else { return }
                        try? await Task.sleep(for: .seconds(1.2))
                        close()
                    }
            }
            if todo.waitingFromEarlier > 0 {
                Text("\(todo.waitingFromEarlier) todo(s) from an earlier share are still waiting for a connection.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
