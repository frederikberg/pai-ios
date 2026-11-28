import PAIKit
import SwiftUI

/// The ways into Todos from outside its screens, shared by the Shortcuts actions and the in-app
/// Quick Actions: each parks a link, as a tapped notification does, so it works before the app has
/// a router and lands the same from both.
@MainActor
enum TodosEntry {
    /// The page Todos was on last on this phone, while it still exists; nil is its home.
    static func lastPage(_ environment: AppEnvironment) -> TodoPage? {
        guard let page = environment.todosPlace.lastPage, let me = environment.todos.me else {
            return environment.todosPlace.lastPage
        }
        switch page {
        case .view(let id): return me.views.contains { $0.id == id } ? page : nil
        case .list(let id): return me.lists.contains { $0.id == id } ? page : nil
        case .tag: return page
        }
    }

    /// Where a door into Todos leads: the page it was on last, or its home.
    static func route(_ environment: AppEnvironment) -> Route {
        lastPage(environment).map(Route.todosPage) ?? .todos
    }

    /// Todos on the page it was on last on this phone; its home before any.
    static func open(_ environment: AppEnvironment) {
        DeepLinkInbox.shared.receive(.todos(page: lastPage(environment), todo: nil))
    }

    /// One view or list.
    static func open(_ page: TodoPage) {
        DeepLinkInbox.shared.receive(.todos(page: page, todo: nil))
    }

    /// The Desk in full, over the page Todos was on last.
    static func openDesk(_ environment: AppEnvironment) {
        environment.todosPlace.requestFullDesk()
        open(environment)
    }

    /// The quick switcher, over the page Todos was on last.
    static func openSwitcher(_ environment: AppEnvironment) {
        environment.todosPlace.requestSwitcher()
        open(environment)
    }

    static func newTodo() {
        DeepLinkInbox.shared.receive(.newTodo)
    }

    static func search(_ environment: AppEnvironment) {
        environment.router.replace(with: [.todos, .todosSearch])
    }
}
