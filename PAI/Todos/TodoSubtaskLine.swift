import PAIKit
import SwiftUI

/// The line that adds a subtask: read by the server's capture parser like the add sheet's line,
/// so "Pack the charger p1 #travel" makes a Next subtask tagged travel, with the same chips while
/// typing. The subtask is placed under its parent and nothing else of the parent's applies.
struct TodoSubtaskLine: View {
    let parentId: String
    let today: String
    /// Told a queued subtask to open once the server has it: the way into its fields.
    var onAddAndOpen: (_ changeId: String, _ todoId: String) -> Void = { _, _ in }

    @Environment(AppEnvironment.self) private var environment
    @State private var draft = TodoCaptureDraft { text in
        guard let client = await MainActor.run(body: { AppEnvironment.shared.connection?.apiClient }) else {
            throw PaiError.transport("Not signed in")
        }
        return try await client.todosParse(text: text, list: nil, source: .ios)
    }

    private var store: TodosStore { environment.todos }

    private var chips: [TodoAddChip] { TodoAddChip.read(draft.answer(for: draft.text), today: today) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Add a subtask", text: $draft.text)
                    .submitLabel(.done)
                    .onSubmit(add)
                if draft.canAdd {
                    Button(action: addAndOpen) {
                        Image(systemName: "chevron.right.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PaiPalette.primary500)
                    .accessibilityLabel("Add and open its fields")
                }
            }
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips) { chip in
                            TodoAddChipView(chip: chip, tagColor: tagColor) {}
                        }
                    }
                }
            }
        }
        .task(id: draft.text) {
            try? await Task.sleep(for: .seconds(TodoCaptureDraft.debounceSeconds))
            guard !Task.isCancelled else { return }
            await draft.read()
        }
        .task {
            #if DEBUG
                if let text = PaiFixtureLaunch.requestedTodosSubtask(), draft.text.isEmpty { draft.text = text }
            #endif
        }
        .fixtureFact("todosSubtaskChips", String(chips.count))
        .fixtureFact("todosSubtaskHorizon", chips.first { $0.kind == "horizon" }?.label ?? "")
    }

    private func tagColor(_ name: String) -> TodoColor {
        TodoIdentity.tagColor(name, chosen: TodoIdentity.chosenTagColors(store.me?.tags ?? []))
    }

    private func add() {
        guard let taken = draft.take() else { return }
        store.capture(text: taken.text, place: .under(parent: parentId), parsed: taken.answer)
    }

    private func addAndOpen() {
        guard let taken = draft.take() else { return }
        let changeId = store.capture(text: taken.text, place: .under(parent: parentId), parsed: taken.answer)
        if let todoId = store.createdTodoId(ofChange: changeId) { onAddAndOpen(changeId, todoId) }
    }
}
