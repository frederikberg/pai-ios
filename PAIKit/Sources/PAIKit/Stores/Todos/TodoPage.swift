import Foundation
import Observation

/// A page of todos: a saved view, one list, or one tag.
public enum TodoPage: Hashable, Sendable {
    case view(String)
    case list(String)
    case tag(String)

    /// The stable key a page's rows are kept under.
    public var key: String {
        switch self {
        case .view(let id): "view:\(id)"
        case .list(let id): "list:\(id)"
        case .tag(let name): "tag:\(name.lowercased())"
        }
    }

    /// The page a ``key`` names; nil for anything else.
    public init?(key: String) {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let value = String(key[key.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch key[..<colon] {
        case "view": self = .view(value)
        case "list": self = .list(value)
        case "tag": self = .tag(value)
        default: return nil
        }
    }
}

/// Where Todos was last on this phone, and a request to open the Desk in full. "Open Todos" (the
/// Shortcuts action, the in-app action) lands on the last page; "Open the Desk" lands there too,
/// with the Desk at full height.
@MainActor
@Observable
public final class TodosPlace {
    @ObservationIgnored private let storage: (any SettingsKeyValueStore)?
    static let lastPageKey = "todos.lastPage"

    /// Set by "Open the Desk"; the page that shows next, or the one on screen, takes it.
    public private(set) var fullDeskWanted = false

    /// `storage` nil keeps nothing between launches (tests, fixture runs).
    public init(storage: (any SettingsKeyValueStore)?) {
        self.storage = storage
    }

    /// The page last shown; nil before any, which opens Todos' home.
    public var lastPage: TodoPage? {
        let key: String? = storage?.value(forKey: Self.lastPageKey)
        return key.flatMap(TodoPage.init(key:))
    }

    public func shown(_ page: TodoPage) {
        storage?.setValue(page.key, forKey: Self.lastPageKey)
    }

    public func requestFullDesk() { fullDeskWanted = true }

    /// Set by the quick switcher action; the page that shows next, or the one on screen, opens it.
    public private(set) var switcherWanted = false

    public func requestSwitcher() { switcherWanted = true }

    /// Whether the switcher is to open, once.
    public func takeSwitcher() -> Bool {
        guard switcherWanted else { return false }
        switcherWanted = false
        return true
    }

    /// Whether the Desk is to show in full, once: the page asking takes the request.
    public func takeFullDesk() -> Bool {
        guard fullDeskWanted else { return false }
        fullDeskWanted = false
        return true
    }
}

/// What a page last read: the groups the server returned (one group "All" for an ungrouped
/// answer), the total, and the cursor of the next rows.
public struct TodoPageResult: Codable, Equatable, Sendable {
    public let groups: [TodoQueryGroup]
    public let total: Int
    public let nextCursor: String?
    /// The log position of the answer; an older answer never replaces a newer one.
    public let seq: Int

    public init(groups: [TodoQueryGroup], total: Int, nextCursor: String?, seq: Int) {
        self.groups = groups
        self.total = total
        self.nextCursor = nextCursor
        self.seq = seq
    }

    /// The groups of an answer, the web's `groupsOf`: an ungrouped answer carries its rows only in
    /// `todos`, so they become one group, in the order given, without the ancestors shown only
    /// for context and without a match that sits under another match (it shows under its parent).
    public static func groups(of answer: TodosQueryAnswer) -> [TodoQueryGroup] {
        if !answer.groups.isEmpty || answer.todos.isEmpty { return answer.groups }
        let byId = Dictionary(answer.todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = answer.todos.filter { todo in
            if todo.context == true { return false }
            guard let parentId = todo.parentId, let parent = byId[parentId] else { return true }
            return parent.context == true
        }.map(\.id)
        return [TodoQueryGroup(key: "all", label: "All", ids: ids)]
    }

    /// This result with the next rows added: a group already held grows, a new one follows.
    func appending(_ more: [TodoQueryGroup], nextCursor: String?) -> TodoPageResult {
        var out = groups
        for group in more {
            if let index = out.firstIndex(where: { $0.key == group.key }) {
                let have = Set(out[index].ids)
                out[index] = TodoQueryGroup(
                    key: group.key, label: group.label, ids: out[index].ids + group.ids.filter { !have.contains($0) })
            } else {
                out.append(group)
            }
        }
        return TodoPageResult(groups: out, total: total, nextCursor: nextCursor, seq: seq)
    }
}
