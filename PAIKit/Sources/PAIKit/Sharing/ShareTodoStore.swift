import Foundation
import Observation

/// "Todo" in the share sheet: shared text or a link becomes a todo through the same capture and
/// outbox the app uses, the link riding along as the todo's link.
///
/// The share extension has no container in common with the app, so it keeps a queue of its own
/// under `storageRoot`: a todo that could not go out waits there and is sent the next time the
/// share sheet opens PAI. The extension holds only the access token, never a renewal, so an
/// expired one waits the same way.
@Observable
@MainActor
public final class ShareTodoStore {

    public enum Phase: Equatable, Sendable {
        case editing
        case sending
        case done(TodosCaptureOutcome)
    }

    /// The todo's words, prefilled from what was shared.
    public var text: String
    public let link: String?
    public private(set) var phase: Phase = .editing

    public let todos: TodosStore

    /// How long the sheet waits for the server before it says the todo waits.
    public static let waitSeconds: TimeInterval = 10

    public init(sharedText: String?, link: String?, todos: TodosStore) {
        self.text = sharedText.map { TodosStore.split($0).words } ?? ""
        self.link = link
        self.todos = todos
    }

    /// The share sheet's store over its own queue. It only reads the disk; `start` sends.
    public convenience init(sharedText: String?, link: String?, storageRoot: URL) {
        let storage = FileTodosStorage(
            rootURL: storageRoot.appendingPathComponent("TodosOutbox", isDirectory: true),
            cacheDirectory: storageRoot.appendingPathComponent("TodosCache", isDirectory: true))
        self.init(sharedText: sharedText, link: link, todos: TodosStore(storage: storage))
    }

    /// Connect to the server, which also sends what an earlier share left behind. Called by the
    /// view that is on screen, never from an initializer a re-created view would run again.
    public func start(_ backend: any TodosBackend) {
        todos.connect(backend)
    }

    public var canAdd: Bool {
        phase == .editing && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || link != nil)
    }

    /// Todos an earlier share could not send, still waiting here.
    public var waitingFromEarlier: Int {
        if case .done(let outcome) = phase { return todos.queue.filter { $0.changeId != outcome.changeId }.count }
        return todos.queue.count
    }

    public func add(timeout: TimeInterval = waitSeconds) async {
        guard canAdd else { return }
        phase = .sending
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = typed.isEmpty ? (link ?? "") : text
        let outcome = await todos.captureAndWait(
            text: words, links: link.map { [.url($0)] } ?? [], source: .share, timeout: timeout)
        phase = .done(outcome)
    }
}
