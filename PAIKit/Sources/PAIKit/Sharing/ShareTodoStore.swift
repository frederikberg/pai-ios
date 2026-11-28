import Foundation
import Observation

/// "Todo" in the share sheet: what was shared becomes a todo through the same capture and outbox
/// the app uses. Shared text is the todo's words, a link rides along as the todo's link, and
/// photos and files become the todo's files.
///
/// The share extension has no container in common with the app, and holds only an access token
/// the app renews, so a todo it could not send would wait for nothing the person does. It keeps
/// nothing on disk: when the server does not answer within the wait, the sheet stays open with
/// the words editable and offers to try again. Trying again with the same words resends the same
/// change, so a first send whose answer was lost replays instead of adding a second todo; once
/// the todo exists, trying again sends only the files that are still missing.
@Observable
@MainActor
public final class ShareTodoStore {

    public enum Phase: Equatable, Sendable {
        case editing
        case sending
        /// Added with everything shared: the sheet can close.
        case added(TodosCaptureOutcome)
        /// Not added; the words stay, and `add` tries again.
        case notAdded(TodosCaptureOutcome)
        /// The todo exists, but this many of its files did not arrive; `add` sends them again.
        case filesMissing(TodosCaptureOutcome, missing: Int)
    }

    /// The todo's words, prefilled from what was shared.
    public var text: String
    public let link: String?
    /// The photos and files that become the todo's files.
    public let files: [ShareItem]
    public private(set) var phase: Phase = .editing

    public let todos: TodosStore

    private struct Attempt {
        let changeId: String
        let text: String
        /// The todo the change makes, read while the change was still queued.
        let todoId: String?
        /// The verdict on the todo itself, once the server gave one.
        var made: TodosCaptureOutcome?
        /// The queued change of each file by the file's id.
        var fileChanges: [String: String] = [:]
    }

    @ObservationIgnored private var attempt: Attempt?

    /// How long the sheet waits for the server before it says the todo was not added.
    public static let waitSeconds: TimeInterval = 10

    public init(
        sharedText: String?, link: String?, files: [ShareItem] = [],
        todos: TodosStore = TodosStore(storage: InMemoryTodosStorage())
    ) {
        self.text = sharedText.map { TodosStore.split($0).words } ?? ""
        self.link = link
        self.files = files
        self.todos = todos
    }

    /// Connect to the server. Called by the view that is on screen.
    public func start(_ backend: any TodosBackend) {
        todos.connect(backend)
    }

    /// Whether the todo itself exists on the server; its words can no longer change then.
    public var isMade: Bool { attempt?.made?.added == true }

    public var canAdd: Bool {
        switch phase {
        case .editing, .notAdded: return !words.isEmpty
        case .filesMissing: return true
        case .sending, .added: return false
        }
    }

    /// What goes to the parser: the typed words, else the link, else the first file's name.
    private var words: String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (link ?? files.first?.name ?? "") : text
    }

    /// What the sheet says under the field once an attempt ended without everything arriving.
    public var problem: String? {
        switch phase {
        case .notAdded(let outcome):
            return outcome.message(keeper: .shareSheet)
        case .filesMissing(let outcome, let missing):
            let what = missing == 1 ? "1 file" : "\(missing) files"
            return "\(outcome.message(keeper: .shareSheet)) \(what) did not arrive yet."
        case .editing, .sending, .added:
            return nil
        }
    }

    public func add(timeout: TimeInterval = waitSeconds) async {
        guard canAdd else { return }
        phase = .sending
        var current = reusableAttempt() ?? begin()
        attempt = current

        if current.made == nil {
            let outcome = await todos.outcome(of: current.changeId, timeout: timeout)
            guard outcome.added else {
                phase = .notAdded(outcome)
                return
            }
            current.made = outcome
            attempt = current
        }
        guard let made = current.made else { return }

        var missing = 0
        for file in files {
            if current.fileChanges[file.id] == nil, let todoId = current.todoId {
                current.fileChanges[file.id] = await queue(file, on: todoId)
                attempt = current
            }
            guard let changeId = current.fileChanges[file.id] else {
                missing += 1
                continue
            }
            let arrived = await todos.outcome(of: changeId, timeout: timeout).added
            if !arrived { missing += 1 }
        }
        phase = missing == 0 ? .added(made) : .filesMissing(made, missing: missing)
    }

    /// The attempt a Try again continues: the todo that exists already, or the queued change
    /// that still carries the same words.
    private func reusableAttempt() -> Attempt? {
        guard let attempt else { return nil }
        if attempt.made != nil {
            todos.retryNow()
            return attempt
        }
        guard attempt.text == words, todos.queue.contains(where: { $0.changeId == attempt.changeId }) else {
            return nil
        }
        todos.retryNow()
        return attempt
    }

    /// Queues the todo, taking back what an earlier attempt with other words queued.
    private func begin() -> Attempt {
        if let attempt {
            todos.withdraw(changeId: attempt.changeId)
            for changeId in attempt.fileChanges.values { todos.withdraw(changeId: changeId) }
        }
        let changeId = todos.capture(text: words, links: link.map { [.url($0)] } ?? [], source: .share)
        return Attempt(changeId: changeId, text: words, todoId: todos.createdTodoId(ofChange: changeId))
    }

    /// Reads one file and queues it as a file of the todo. Nil when it could not be read or kept.
    private func queue(_ file: ShareItem, on todoId: String) async -> String? {
        let prepare = file.prepare
        guard let upload = try? await Task.detached(operation: { try prepare() }).value else { return nil }
        return todos.attach(todoId: todoId, name: upload.filename, contentType: upload.mimeType, data: upload.data)
    }
}
