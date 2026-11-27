import Foundation
import Observation

/// The user's Quick Actions arrangement and every change the editor makes to it, each written to
/// storage as it happens. Kept on this phone, never synced.
///
/// Not main-actor isolated, like ``SleepModeStore``; the app touches it from the main actor only.
@Observable
public final class QuickActionsStore {
    static let storageKey = "quickActionsArrangement"

    public private(set) var arrangement: QuickActionArrangement {
        didSet { storage?.setValue(arrangement, forKey: Self.storageKey) }
    }

    @ObservationIgnored private let storage: SettingsKeyValueStore?

    /// `storage` `nil` keeps nothing between launches, which is what a screenshot run wants.
    public init(storage: SettingsKeyValueStore?) {
        self.storage = storage
        arrangement = storage?.value(forKey: Self.storageKey) ?? .standard
    }

    public var grid: [QuickActionItem] { arrangement.grid }
    public var more: [QuickActionItem] { arrangement.more }
    public var hidden: [QuickActionItem] { arrangement.hidden }
    public var shortcuts: [QuickActionShortcut] { arrangement.shortcuts }

    public func items(in placement: QuickActionPlacement) -> [QuickActionItem] {
        switch placement {
        case .grid: grid
        case .more: more
        case .hidden: hidden
        }
    }

    public func placement(of item: QuickActionItem) -> QuickActionPlacement {
        arrangement.placement(of: item)
    }

    public func shortcut(_ id: UUID) -> QuickActionShortcut? {
        arrangement.shortcut(id)
    }

    /// Reorders the grid or the More list the way a `List`'s `onMove` reports it: the rows at
    /// `source` land before the row that was at `destination`. Hidden has no order of its own.
    public func move(in placement: QuickActionPlacement, fromOffsets source: IndexSet, toOffset destination: Int) {
        switch placement {
        case .grid: arrangement.grid = Self.moved(arrangement.grid, from: source, to: destination)
        case .more: arrangement.more = Self.moved(arrangement.more, from: source, to: destination)
        case .hidden: break
        }
    }

    /// Puts `item` at the end of `placement`'s list, taking it off the other. The More tile stays
    /// on the grid.
    public func place(_ item: QuickActionItem, in placement: QuickActionPlacement) {
        guard item != .more, self.placement(of: item) != placement else { return }
        var next = arrangement
        next.grid.removeAll { $0 == item }
        next.more.removeAll { $0 == item }
        switch placement {
        case .grid: next.grid.append(item)
        case .more: next.more.append(item)
        case .hidden: break
        }
        arrangement = next
    }

    /// Makes a shortcut and puts it at the end of the grid, where it is seen at once.
    @discardableResult
    public func addShortcut(name: String, urlString: String) -> QuickActionShortcut {
        let shortcut = QuickActionShortcut(name: name, urlString: urlString)
        var next = arrangement
        next.shortcuts.append(shortcut)
        next.grid.append(.shortcut(shortcut.id))
        arrangement = next
        return shortcut
    }

    /// Adds a tile for one Todos view or list at the end of the grid; one already added stays where it is.
    public func addTodosPage(_ page: TodoPage) {
        guard !arrangement.todosPages.contains(page.key) else { return }
        var next = arrangement
        next.todosPages.append(page.key)
        next.grid.append(.todosPage(page.key))
        arrangement = next
    }

    public func deleteTodosPage(_ key: String) {
        var next = arrangement
        next.todosPages.removeAll { $0 == key }
        next.normalize()
        arrangement = next
    }

    public func updateShortcut(_ shortcut: QuickActionShortcut) {
        guard let index = arrangement.shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        arrangement.shortcuts[index] = shortcut
    }

    public func deleteShortcut(_ id: UUID) {
        var next = arrangement
        next.shortcuts.removeAll { $0.id == id }
        next.normalize()
        arrangement = next
    }

    /// Back to ``QuickActionArrangement/standard``; the shortcuts and Todos pages stay, hidden.
    public func resetToStandard() {
        arrangement = QuickActionArrangement(
            grid: QuickActionArrangement.standard.grid, more: QuickActionArrangement.standard.more,
            shortcuts: arrangement.shortcuts, todosPages: arrangement.todosPages)
    }

    /// `Array.move(fromOffsets:toOffset:)` is SwiftUI's, which the package does not import.
    static func moved<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        let valid = source.filter { items.indices.contains($0) }
        let moving = valid.map { items[$0] }
        var rest: [T] = []
        var insertAt = 0
        for (index, item) in items.enumerated() where !valid.contains(index) {
            if index < destination { insertAt += 1 }
            rest.append(item)
        }
        rest.insert(contentsOf: moving, at: insertAt)
        return rest
    }
}
