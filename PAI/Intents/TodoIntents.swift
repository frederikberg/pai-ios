import AppIntents
import Foundation
import PAIKit

/// Add a todo without opening the app: Siri, Shortcuts, or the Action button through a shortcut.
/// The words go to the server's capture parser (dates, `#tags`, `/List`, `*` for the desk), the
/// same reading the web's quick add and the `todo` CLI get.
///
/// Queued through the app's one Todos store rather than a standalone client: without a network
/// or a sign-in the todo waits on the phone, on disk, and goes out the next time PAI is open, so
/// nothing said is lost. The answer waits a few seconds for the server, then says where the todo
/// is; words that are only spaces queue nothing and say so.
struct AddTodoIntent: AppIntent {
    static var title: LocalizedStringResource { "Add Todo" }
    static var description: IntentDescription {
        IntentDescription("Add a todo to Todos in PAI. Dates, #tags and /List in the words are read.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Todo", requestValueDialog: "What's the todo?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Todos")
    }

    init() {}

    init(text: String) {
        self.text = text
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await AppEnvironment.shared.todos.captureAndWait(
            text: text, source: .shortcut, timeout: Self.waitSeconds)
        let message = outcome.message(keeper: .intent)
        if case .refused = outcome.settlement { throw AddTodoIntentError(message: message) }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
    }

    /// Long enough for a parse and a write on a slow network, short enough for Siri.
    static let waitSeconds: TimeInterval = 8
}

struct AddTodoIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}
