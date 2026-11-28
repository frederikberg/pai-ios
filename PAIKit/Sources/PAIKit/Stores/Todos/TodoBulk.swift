import Foundation

/// An action on several selected todos as one change, so one Undo takes all of it back: the
/// web's `shell/bulk.ts` and `shell/bulkRun.ts` by the same rules.
public enum TodoBulk {
    public enum Action: Equatable, Sendable {
        /// Completes the open ones; reopens when none is open.
        case complete
        /// Puts the ones not on the desk on it; takes all off when all are on it.
        case desk
        case horizon(TodoHorizon)
        case tag(String)
        case untag(String)
        /// A day for all, each keeping its own time unless one is given; nil clears the day.
        case when(TodoWhen?)
        case someday(Bool)
        /// A deadline for all, each keeping its own lead days; nil clears it.
        case deadline(date: String?)
        case repeatRule([String: PaiJSONValue]?)
        case nudge(TodoFieldOps.NudgeChoice)
        case move(list: String)
        case delete

        /// What belongs to the person, not to the todo: a list that takes no changes still
        /// takes these.
        var isOwn: Bool {
            switch self {
            case .desk, .nudge: true
            default: false
            }
        }
    }

    public struct Change: Equatable, Sendable {
        public let ops: [TodoOp]
        /// What the toast that offers Undo says.
        public let toast: String
    }

    /// What an action does to a selection: the change to send (nil when it would do nothing) and,
    /// when some of the selected may not be changed by this person, the sentence that says how
    /// many were left out and why.
    public struct Plan: Equatable, Sendable {
        public let change: Change?
        public let leftOut: String?
    }

    private static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    /// The selected todos that are not under another selected todo: moving or deleting a parent
    /// takes its subtree along, so the same op for a child would only conflict with it.
    static func topOfSelection(_ ids: [String], todos: [String: Todo]) -> [String] {
        let chosen = Set(ids)
        return ids.filter { id in
            var seen: Set<String> = [id]
            var at = todos[id]?.parentId
            while let parent = at, !seen.contains(parent) {
                if chosen.contains(parent) { return false }
                seen.insert(parent)
                at = todos[parent]?.parentId
            }
            return true
        }
    }

    /// One change for an action on everything selected. `makeId` names each new nudge.
    public static func change(
        _ action: Action, ids: [String], todos: [String: Todo], makeId: () -> String = { TodosStore.uuidv7() }
    ) -> Change? {
        let known = ids.filter { todos[$0] != nil }
        guard !known.isEmpty else { return nil }
        let all = plural(known.count, "todo")
        switch action {
        case .complete:
            let open = known.filter { todos[$0]?.status == .open }
            if !open.isEmpty {
                return Change(ops: open.map { TodoOp.complete(todo: $0) }, toast: "Completed \(plural(open.count, "todo"))")
            }
            return Change(ops: known.map { TodoOp.reopen(todo: $0) }, toast: "Reopened \(all)")
        case .desk:
            let missing = known.filter { todos[$0]?.onDesk != true }
            if missing.isEmpty {
                return Change(ops: known.map { TodoOp.deskRemove(item: $0) }, toast: "Took \(all) off the desk")
            }
            // Each goes to the top, so the last one added is first: reversed, the selection
            // keeps its order.
            return Change(
                ops: missing.reversed().map { TodoOp.deskAdd(todo: $0, position: .first) },
                toast: "Put \(plural(missing.count, "todo")) on the desk")
        case .horizon(let horizon):
            return Change(
                ops: known.map { TodoFieldOps.horizon($0, horizon) }, toast: "Changed the horizon of \(all)")
        case .tag(let raw):
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("#") || name.hasPrefix("@") { name.removeFirst() }
            guard !name.isEmpty else { return nil }
            return Change(
                ops: known.map { TodoFieldOps.tag($0, add: [name]) }, toast: "Tagged \(all) \u{201C}\(name)\u{201D}")
        case .untag(let raw):
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return Change(
                ops: known.map { TodoFieldOps.tag($0, remove: [name]) }, toast: "Took \u{201C}\(name)\u{201D} off \(all)")
        case .when(let when):
            guard let when else {
                return Change(ops: known.map { TodoFieldOps.when($0, date: nil) }, toast: "Cleared the day of \(all)")
            }
            let ops = known.map { id in
                TodoFieldOps.when(id, date: when.date, time: when.time ?? todos[id]?.when?.time.map { String($0.prefix(5)) })
            }
            return Change(ops: ops, toast: "Set the day of \(all)")
        case .someday(let on):
            return Change(
                ops: known.map { TodoFieldOps.someday($0, on) },
                toast: on ? "Moved \(all) to someday" : "Took \(all) out of someday")
        case .deadline(let date):
            guard let date else {
                return Change(
                    ops: known.map { TodoFieldOps.deadline($0, date: nil) }, toast: "Cleared the deadline of \(all)")
            }
            let ops = known.map { TodoFieldOps.deadline($0, date: date, leadDays: todos[$0]?.deadline?.leadDays) }
            return Change(ops: ops, toast: "Set the deadline of \(all)")
        case .repeatRule(let rule):
            return Change(
                ops: known.map { TodoFieldOps.repeat($0, rule) },
                toast: rule == nil ? "Stopped the repeat of \(all)" : "Set a repeat on \(all)")
        case .nudge(let choice):
            return Change(
                ops: known.map { TodoFieldOps.nudgeSet($0, choice, id: makeId()) }, toast: "Added a nudge to \(all)")
        case .move(let list):
            let tops = topOfSelection(known, todos: todos).filter { todos[$0]?.listId != list }
            guard !tops.isEmpty else { return nil }
            return Change(
                ops: tops.map { TodoFieldOps.move($0, toList: list) }, toast: "Moved \(plural(tops.count, "todo"))")
        case .delete:
            let tops = topOfSelection(known, todos: todos)
            return Change(ops: tops.map { TodoFieldOps.delete($0) }, toast: "Deleted \(plural(tops.count, "todo"))")
        }
    }

    /// The change for what this person may change among the selected. A todo in a list that
    /// takes no changes from them is left out, and `leftOut` says how many and why; an action on
    /// the person's own things (the desk, nudges) leaves none out.
    public static func plan(
        _ action: Action, ids: [String], todos: [String: Todo], lists: [TodoList],
        makeId: () -> String = { TodosStore.uuidv7() }
    ) -> Plan {
        func blocked(_ id: String) -> String? {
            guard let todo = todos[id] else { return nil }
            return TodoPermissions.tickBlockedReason(lists.first { $0.id == todo.listId })
        }
        let writable = action.isOwn ? ids : ids.filter { blocked($0) == nil }
        var leftOut: String?
        if writable.count < ids.count {
            let reason = ids.lazy.compactMap(blocked).first ?? "These cannot be changed."
            leftOut = writable.isEmpty ? reason : "\(ids.count - writable.count) of \(ids.count) left out: \(reason)"
        }
        return Plan(change: change(action, ids: writable, todos: todos, makeId: makeId), leftOut: leftOut)
    }

    /// What the selected have in common, for a picker opened on all of them: a field every one
    /// agrees on shows as set, and a tag only when every one carries it.
    public static func common(_ ids: [String], todos: [String: Todo]) -> TodoEntryValues {
        let chosen = ids.compactMap { todos[$0] }
        var values = TodoEntryValues()
        guard let first = chosen.first else { return values }
        if chosen.allSatisfy({ $0.when == first.when }) { values.when = first.when }
        values.someday = chosen.allSatisfy(\.someday)
        if chosen.allSatisfy({ $0.deadline?.date == first.deadline?.date }) { values.deadline = first.deadline }
        if chosen.allSatisfy({ $0.horizon == first.horizon }) { values.horizon = first.horizon }
        if chosen.allSatisfy({ $0.listId == first.listId }) { values.listId = first.listId }
        values.tags = first.tags.filter { tag in chosen.allSatisfy { $0.tags.contains(tag) } }
        values.onDesk = chosen.allSatisfy(\.onDesk)
        return values
    }
}
