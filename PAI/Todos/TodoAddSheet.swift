import PAIKit
import SwiftUI

/// One line for a new todo, keyboard up: what the New todo control and the Home Screen quick
/// action open. What the server's parser reads in the line shows as chips while typing; Add
/// queues the todo whether or not the parser has answered, and the sheet closes at once.
struct TodoAddSheet: View {
    let todos: TodosStore
    @State var draft: TodoCaptureDraft
    /// Told the id of the queued change, so whoever presented the sheet can say how it went.
    let onAdded: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("New todo", text: $draft.text, axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(add)
                if !draft.chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(draft.chips.enumerated()), id: \.offset) { _, chip in
                                Text(chip)
                                    .font(.footnote)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                        }
                    }
                }
                ForEach(draft.issues, id: \.self) { issue in
                    Text(issue).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("New todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(!draft.canAdd)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: draft.text) {
            try? await Task.sleep(for: .seconds(TodoCaptureDraft.debounceSeconds))
            guard !Task.isCancelled else { return }
            await draft.read()
        }
        .task { focused = true }
    }

    private func add() {
        guard let taken = draft.take() else { return }
        onAdded(todos.capture(text: taken.text, parsed: taken.answer))
        dismiss()
    }
}
