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

/// Add todos by saying what needs doing in plain words: Siri, Shortcuts, or the Action button
/// through a shortcut. A model on the server reads the words into one or several todos, with
/// their days, tags and subtasks, queued as one change. Without a network the words are queued as
/// typed, read by the capture parser like Add Todo's, so nothing said is lost.
struct DescribeTodoIntent: AppIntent {
    static var title: LocalizedStringResource { "Describe Todo" }
    static var description: IntentDescription {
        IntentDescription("Say what needs doing in plain words; Todos in PAI makes the todos from it.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Words", requestValueDialog: "What needs doing?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Describe \(\.$text) to Todos")
    }

    init() {}

    init(text: String) {
        self.text = text
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await AppEnvironment.shared.todos.describeAndWait(
            text: text, source: .shortcut, timeout: AddTodoIntent.waitSeconds)
        let message = outcome.message(keeper: .intent)
        if case .refused = outcome.settlement { throw AddTodoIntentError(message: message) }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
    }
}

struct AddTodoIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

/// A Todos view or list, as the Shortcuts app picks it: by name, stored by id, so a shortcut keeps
/// opening the right one after a rename.
struct TodosPageEntity: AppEntity, Identifiable, Hashable {
    /// The page's `TodoPage.key`: `view:<id>` or `list:<id>`.
    let id: String
    let name: String
    let kind: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Todos View" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind)")
    }

    static var defaultQuery: TodosPageEntityQuery { TodosPageEntityQuery() }
}

/// The views and lists Shortcuts offers: what the phone holds, else what the server answers.
/// Every failure is an empty list, which reads as nothing set up yet rather than a broken shortcut.
struct TodosPageEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TodosPageEntity] {
        let wanted = Set(identifiers)
        return await all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [TodosPageEntity] {
        let needle = string.lowercased()
        guard !needle.isEmpty else { return await all() }
        return await all().filter { $0.name.lowercased().contains(needle) }
    }

    func suggestedEntities() async throws -> [TodosPageEntity] { await all() }

    private func all() async -> [TodosPageEntity] {
        var me = await MainActor.run { AppEnvironment.shared.todos.me }
        if me == nil, let client = await AppEnvironment.standaloneClient() {
            me = try? await client.todosMe()
        }
        return TodoBrowse.places(me).map { TodosPageEntity(id: $0.page.key, name: $0.title, kind: $0.kind) }
    }
}

/// Open Todos where it was last on this phone.
struct OpenTodosIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Todos" }
    static var description: IntentDescription {
        IntentDescription("Open Todos in PAI on the view it was on last.")
    }
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        TodosEntry.open(AppEnvironment.shared)
        return .result()
    }
}

/// Open Todos on one view or list, picked once when the shortcut is made.
struct OpenTodosViewIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Todos View" }
    static var description: IntentDescription {
        IntentDescription("Open a view or a list in Todos in PAI.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "View or list")
    var page: TodosPageEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$page) in Todos")
    }

    init() {}

    init(page: TodosPageEntity) {
        self.page = page
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let target = TodoPage(key: page.id) {
            TodosEntry.open(target)
        } else {
            TodosEntry.open(AppEnvironment.shared)
        }
        return .result()
    }
}

/// Open the Desk in full, over the view Todos was on last.
struct OpenTodosDeskIntent: AppIntent {
    static var title: LocalizedStringResource { "Open the Desk" }
    static var description: IntentDescription {
        IntentDescription("Open the Desk of Todos in PAI at full height.")
    }
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        TodosEntry.openDesk(AppEnvironment.shared)
        return .result()
    }
}
