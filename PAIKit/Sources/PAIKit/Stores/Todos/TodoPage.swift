import Foundation

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
