import Foundation

/// The desk above a list on a phone, the web's `PhoneDesk` (pai-cloud `docs/architecture/todos.md`
/// → *Panes*): a bar that says how much is on it and what comes first, the split (the desk over
/// the list, each with its own scroll), or the desk alone with the list folded to one line.
public enum TodoDeskMode: String, CaseIterable, Sendable {
    case bar, split, desk
}

/// Which pages remember their own desk state: Today (a day plan, opened split) and every other
/// list, each remembered apart, per device.
public enum TodoDeskPageKind: String, Sendable {
    case today, list

    /// A page is Today when its view is the built-in Today or is laid out as one.
    public static func of(view: TodoView?) -> TodoDeskPageKind {
        guard let view else { return .list }
        return view.builtin == "today" || view.layout == "today" ? .today : .list
    }

    public var defaultMode: TodoDeskMode {
        switch self {
        case .today: .split
        case .list: .bar
        }
    }
}

/// The desk state per page kind, kept on the device.
@MainActor
public final class TodoDeskModes {
    private let storage: (any SettingsKeyValueStore)?
    private var held: [TodoDeskPageKind: TodoDeskMode] = [:]

    static func key(_ kind: TodoDeskPageKind) -> String { "todos.deskMode.\(kind.rawValue)" }

    /// `storage` nil keeps nothing between launches (tests, fixture runs).
    public init(storage: (any SettingsKeyValueStore)?) {
        self.storage = storage
    }

    public func mode(for kind: TodoDeskPageKind) -> TodoDeskMode {
        if let mode = held[kind] { return mode }
        let stored: String? = storage?.value(forKey: Self.key(kind))
        return stored.flatMap(TodoDeskMode.init(rawValue:)) ?? kind.defaultMode
    }

    public func set(_ mode: TodoDeskMode, for kind: TodoDeskPageKind) {
        held[kind] = mode
        storage?.setValue(mode.rawValue, forKey: Self.key(kind))
    }
}

/// One row of a page: a group's heading, or a todo at its depth under an opened parent.
public enum TodoListRow: Equatable, Sendable, Identifiable {
    case heading(key: String, label: String, count: Int)
    case todo(id: String, depth: Int, expandable: Bool, expanded: Bool)

    public var id: String {
        switch self {
        case .heading(let key, _, _): "group:\(key)"
        case .todo(let id, _, _, _): "todo:\(id)"
        }
    }
}

public enum TodoRows {
    /// The rows of a page: each group under its heading (no heading for the one group of an
    /// ungrouped answer), todos made here first in the first group, and under each opened row its
    /// open children, each openable in turn. A row whose todo is not known is left out.
    public static func build(
        result: TodoPageResult?, pending: [String], todos: [String: Todo], expanded: Set<String>,
        children: [String: [String]]
    ) -> [TodoListRow] {
        let groups = result?.groups ?? []
        var rows: [TodoListRow] = []
        var placed = Set<String>()
        func add(_ id: String, depth: Int) {
            guard let todo = todos[id], placed.insert(id).inserted else { return }
            let open = expanded.contains(id)
            rows.append(.todo(id: id, depth: depth, expandable: todo.childrenOpen > 0, expanded: open))
            guard open else { return }
            for child in children[id] ?? [] { add(child, depth: depth + 1) }
        }
        let headed = groups.count > 1 || (groups.first.map { $0.key != "all" } ?? false)
        if groups.isEmpty {
            for id in pending { add(id, depth: 0) }
        }
        for (index, group) in groups.enumerated() {
            let ids = (index == 0 ? pending : []) + group.ids
            let known = ids.filter { todos[$0] != nil }
            if headed, !known.isEmpty { rows.append(.heading(key: group.key, label: group.label, count: known.count)) }
            for id in ids { add(id, depth: 0) }
        }
        return rows
    }
}

/// What a row says about its todo, the web's `TodoRow` without the mouse: the title, one quiet
/// line (the description's first line, the checklist, matches inside, the first tag and how many
/// more, the list when the page holds several), and the date chip.
public struct TodoRowModel: Equatable, Sendable {
    public struct Tag: Equatable, Sendable {
        public let name: String
        public let color: TodoColor
    }

    public let title: String
    public let preview: String?
    public let checklist: String?
    public let inside: Int
    public let tags: [Tag]
    public let moreTags: Int
    public let listName: String?
    public let listColor: TodoColor?
    public let date: TodoDates.Chip?
    public let repeats: Bool
    public let done: Bool
    public let horizon: TodoHorizonMark

    /// How many tags a row names before it counts the rest.
    public static let visibleTags = 1

    public static func make(
        _ todo: Todo, today: String?, leadDays: Int, tagColor: (String) -> TodoColor, list: TodoList?
    ) -> TodoRowModel {
        let tags = todo.tags.prefix(visibleTags).map { Tag(name: $0, color: tagColor($0)) }
        return TodoRowModel(
            title: todo.title, preview: todo.bodyPreview.isEmpty ? nil : todo.bodyPreview,
            checklist: todo.checklist.map { "\($0.done)/\($0.total)" }, inside: todo.foldedIds?.count ?? 0,
            tags: Array(tags), moreTags: max(0, todo.tags.count - visibleTags), listName: list?.name,
            listColor: list.map { TodoIdentity.of(list: $0).color },
            date: today.flatMap {
                TodoDates.chip(when: todo.when, deadline: todo.deadline, today: $0, leadDays: leadDays)
            },
            repeats: todo.repeat != nil, done: todo.status != .open, horizon: TodoHorizonMark.of(todo.horizon))
    }
}

/// The phone's Browse screen: the web's sidebar sections (favourite views with their counts, the
/// other views, the lists with their counts and a lock, the tags) in its order.
public struct TodoBrowse: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let identity: TodoIdentity
        public let count: Int?
        public let locked: Bool
        public let page: TodoPage?
    }

    public let favourites: [Entry]
    public let moreViews: [Entry]
    public let lists: [Entry]
    public let tags: [Entry]
    /// The tags fold once the person has views of their own.
    public let tagsFolded: Bool

    public static func make(me: TodosMeAnswer?, viewCounts: [String: Int]) -> TodoBrowse {
        let tags = me?.tags ?? []
        let chosen = TodoIdentity.chosenTagColors(tags)
        let tagColor = { TodoIdentity.tagColor($0, chosen: chosen) }
        let views = (me?.views ?? []).sorted { $0.rank < $1.rank }
        func entry(_ view: TodoView) -> Entry {
            Entry(
                id: view.id, title: view.name, identity: TodoIdentity.of(view: view, tagColor: tagColor),
                count: viewCounts[view.id], locked: false, page: .view(view.id))
        }
        let lists = (me?.lists ?? []).filter { !$0.archived }.map {
            Entry(
                id: $0.id, title: $0.name, identity: TodoIdentity.of(list: $0), count: $0.counts.open,
                locked: $0.locked,
                page: .list($0.id))
        }
        var tagCounts: [String: (name: String, count: Int)] = [:]
        for tag in tags {
            let key = tag.name.lowercased()
            tagCounts[key] = (tagCounts[key]?.name ?? tag.name, (tagCounts[key]?.count ?? 0) + tag.openCount)
        }
        let tagEntries = tagCounts.values.sorted { $0.name.lowercased() < $1.name.lowercased() }.map {
            Entry(
                id: "tag:\($0.name.lowercased())", title: $0.name,
                identity: TodoIdentity(icon: .hash, color: tagColor($0.name)), count: $0.count, locked: false,
                page: .tag($0.name))
        }
        return TodoBrowse(
            favourites: views.filter(\.pinned).map(entry), moreViews: views.filter { !$0.pinned }.map(entry),
            lists: lists, tags: tagEntries, tagsFolded: views.contains { $0.builtin == nil })
    }

    /// The view a bare Todos opens: the first favourite in the person's own order.
    public static func home(_ me: TodosMeAnswer?) -> TodoView? {
        let views = (me?.views ?? []).sorted { $0.rank < $1.rank }
        return views.first(where: \.pinned) ?? views.first
    }
}

/// What a person may change in a list, the web's `changeBlockedReason` for ticking: owners and
/// editors may, a filer and a viewer may not, and a locked list takes no change from anyone here.
/// The desk is the person's own and is never blocked.
public enum TodoPermissions {
    public static func tickBlockedReason(_ list: TodoList?) -> String? {
        guard let list else { return nil }
        if list.locked { return "This list is locked and read-only, so it cannot be changed." }
        switch list.role {
        case .owner, .editor: return nil
        case .viewer: return "This list is read-only for you."
        case .filer: return "On this list you can add todos and change your own. Nothing else."
        case .unrecognized: return "You are not allowed to do that here."
        }
    }
}
