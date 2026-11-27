import PAIKit
import SwiftUI

/// The ways into Todos from outside its screens, shared by the Shortcuts actions and the in-app
/// Quick Actions: each parks a link, as a tapped notification does, so it works before the app has
/// a router and lands the same from both.
@MainActor
enum TodosEntry {
    /// Todos on the page it was on last on this phone; its home before any.
    static func open(_ environment: AppEnvironment) {
        DeepLinkInbox.shared.receive(.todos(page: environment.todosPlace.lastPage, todo: nil))
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
