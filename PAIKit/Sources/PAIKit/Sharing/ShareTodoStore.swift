import Foundation
import Observation

/// "Todo" in the share sheet: shared text or a link becomes a todo through the same capture and
/// outbox the app uses, the link riding along as the todo's link.
///
/// The share extension has no container in common with the app, and holds only an access token
/// the app renews, so a todo it could not send would wait for nothing the person does. It keeps
/// nothing on disk: when the server does not answer within the wait, the sheet stays open with
/// the words editable and offers to try again. Trying again with the same words resends the same
/// change, so a first send whose answer was lost replays instead of adding a second todo.
@Observable
@MainActor
public final class ShareTodoStore {

    public enum Phase: Equatable, Sendable {
        case editing
        case sending
        /// Added: the sheet can close.
        case added(TodosCaptureOutcome)
        /// Not added; the words stay, and `add` tries again.
        case notAdded(TodosCaptureOutcome)
    }

    /// The todo's words, prefilled from what was shared.
    public var text: String
    public let link: String?
    public private(set) var phase: Phase = .editing

    public let todos: TodosStore
    /// The change the last attempt queued and the words it carried.
    @ObservationIgnored private var pending: (changeId: String, text: String)?

    /// How long the sheet waits for the server before it says the todo was not added.
    public static let waitSeconds: TimeInterval = 10

    public init(sharedText: String?, link: String?, todos: TodosStore = TodosStore(storage: InMemoryTodosStorage())) {
        self.text = sharedText.map { TodosStore.split($0).words } ?? ""
        self.link = link
        self.todos = todos
    }

    /// Connect to the server. Called by the view that is on screen.
    public func start(_ backend: any TodosBackend) {
        todos.connect(backend)
    }

    public var canAdd: Bool {
        switch phase {
        case .editing, .notAdded: return !words.isEmpty
        case .sending, .added: return false
        }
    }

    /// What goes to the parser: the typed words, or the link when nothing is typed.
    private var words: String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (link ?? "") : text
    }

    public func add(timeout: TimeInterval = waitSeconds) async {
        guard canAdd else { return }
        phase = .sending
        let outcome: TodosCaptureOutcome
        if let pending, pending.text == words, todos.queue.contains(where: { $0.changeId == pending.changeId }) {
            todos.retryNow()
            outcome = await todos.outcome(of: pending.changeId, timeout: timeout)
        } else {
            if let pending { todos.withdraw(changeId: pending.changeId) }
            let changeId = todos.capture(text: words, links: link.map { [.url($0)] } ?? [], source: .share)
            pending = (changeId, words)
            outcome = await todos.outcome(of: changeId, timeout: timeout)
        }
        phase = outcome.added ? .added(outcome) : .notAdded(outcome)
    }
}
