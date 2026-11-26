import AppIntents
import Foundation
import PAIKit

// Compiled into the app and into the controls extension, for the same reason as
// `OpenQuickActionsIntent`: the control opens the app only when the app holds this very type.

/// Open the New todo sheet with the keyboard up — what the New todo control opens, and
/// available to Shortcuts and the Action button on its own.
struct OpenNewTodoIntent: AppIntent {
    static var title: LocalizedStringResource { "New Todo" }
    static var description: IntentDescription {
        IntentDescription("Open PAI on a new todo, ready to type.")
    }
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkInbox.shared.receive(.newTodo)
        return .result()
    }
}
