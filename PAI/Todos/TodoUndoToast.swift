import PAIKit
import SwiftUI

/// What a change did, said in a toast with Undo, the web's `submit(ops, {toast})`: Undo takes
/// the change back through `TodosStore.undo`, whether it already reached the server or still
/// waits on the phone, and says how that went.
@MainActor
enum TodoUndoToast {
    /// Long enough to notice a slip and reach the button, as the web's toast stays until it is
    /// closed.
    static let lifetimeNanos: UInt64 = 8_000_000_000

    static func show(_ text: String, changeId: String, store: TodosStore, toasts: ToastCenter) {
        let action = ToastMessage.Action(label: "Undo") {
            Task { @MainActor in
                let outcome = await store.undo(changeId: changeId)
                guard let message = outcome.message else { return }
                toasts.show(message, kind: outcome == .undone ? .info : .error)
            }
        }
        toasts.show(text, kind: .info, action: action, lifetimeNanos: lifetimeNanos)
        #if DEBUG
            FixtureFacts.shared.record("todosUndoToast", "shown")
        #endif
    }

    /// Ticks or reopens a todo; a tick says so with Undo, since a tick on a repeating todo moves
    /// it to its next day, where a second tap would complete that round too.
    @discardableResult
    static func toggleDone(_ todo: Todo, store: TodosStore, toasts: ToastCenter) -> String? {
        guard let changeId = store.toggleDone(todoId: todo.id) else { return nil }
        if todo.status == .open {
            show("Completed \u{201C}\(todo.title)\u{201D}", changeId: changeId, store: store, toasts: toasts)
        }
        return changeId
    }
}
