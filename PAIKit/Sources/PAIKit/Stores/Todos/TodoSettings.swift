import Foundation

/// The ops Todos' settings send, the web's Settings sections (`settings/GeneralPanel.tsx`,
/// `NudgesPanel.tsx`, `manage/ListsPanel.tsx`, `TagsPanel.tsx`, `ShareDialog.tsx`, the sidebar's
/// favourite toggle) op for op, so a setting changed on the phone is the change the browser makes.
public enum TodoSettingsOps {
    private static func op(_ name: String, _ fields: [String: PaiJSONValue]) -> TodoOp {
        var all = fields
        all["op"] = .string(name)
        return TodoOp(fields: all)
    }

    private static func prefs(_ fields: [String: PaiJSONValue]) -> TodoOp { op("prefs.set", fields) }

    private static func number(_ value: Int) -> PaiJSONValue { .number(Decimal(value)) }

    // MARK: General

    public static func timezone(_ zone: String) -> TodoOp { prefs(["timezone": .string(zone)]) }

    /// `HH:MM`: what is finished before it belongs to the day before.
    public static func dayRollover(_ time: String) -> TodoOp { prefs(["day_rollover": .string(time)]) }

    /// How many days ahead a deadline shows in Today, held to what the server takes.
    public static func deadlineLeadDays(_ days: Int) -> TodoOp {
        prefs(["deadline_lead_days": number(min(365, max(0, days)))])
    }

    /// Where a new todo goes; nil is the person's own personal list.
    public static func defaultList(_ listId: String?) -> TodoOp {
        prefs(["default_list": listId.map(PaiJSONValue.string) ?? .null])
    }

    /// The whole object, as the web sends it: the server replaces all three kinds at once.
    public static func defaultNudges(_ nudges: TodoDefaultNudges) -> TodoOp {
        func entries(_ list: [TodoDefaultNudges.Entry]) -> PaiJSONValue {
            .array(
                list.map { entry in
                    var fields: [String: PaiJSONValue] = [:]
                    if let minutes = entry.minutes { fields["minutes"] = number(minutes) }
                    if let days = entry.days { fields["days"] = number(days) }
                    if let time = entry.time { fields["time"] = .string(String(time.prefix(5))) }
                    return .object(fields)
                })
        }
        return prefs([
            "default_nudges": .object([
                "timed": entries(nudges.timed), "day": entries(nudges.day), "deadline": entries(nudges.deadline),
            ])
        ])
    }

    // MARK: Lists

    /// A list name as the web takes it: trimmed, at most 80 characters, never empty.
    static func listName(_ text: String) -> String? {
        let name = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return name.isEmpty ? nil : name
    }

    public static func listCreate(id: String, name: String, layout: String) -> TodoOp? {
        guard let name = listName(name) else { return nil }
        return op(
            "list.create",
            ["id": .string(id), "name": .string(name), "kind": .string("shared"), "layout": .string(layout)])
    }

    public static func listRename(_ list: TodoList, _ name: String) -> TodoOp? {
        guard let name = listName(name), name != list.name else { return nil }
        return op("list.update", ["id": .string(list.id), "name": .string(name)])
    }

    public static func listLayout(_ list: TodoList, _ layout: String) -> TodoOp {
        op("list.update", ["id": .string(list.id), "layout": .string(layout)])
    }

    public static func listLocked(_ list: TodoList, _ locked: Bool) -> TodoOp {
        op("list.update", ["id": .string(list.id), "locked": .bool(locked)])
    }

    /// A colour of the palette, or nil to wear the one its name derives.
    public static func listColor(_ list: TodoList, _ color: TodoColor?) -> TodoOp {
        op("list.update", ["id": .string(list.id), "color": color.map { .string($0.rawValue) } ?? .null])
    }

    /// A symbol, or nil for the one its kind has.
    public static func listIcon(_ list: TodoList, _ icon: TodoIcon?) -> TodoOp {
        op("list.update", ["id": .string(list.id), "icon": icon.map { .string($0.rawValue) } ?? .null])
    }

    public static func listArchive(_ list: TodoList) -> TodoOp { op("list.archive", ["id": .string(list.id)]) }

    // MARK: People

    public static func share(_ list: TodoList, email: String, role: TodoRole) -> TodoOp {
        op(
            "member.set",
            [
                "list": .string(list.id), "email": .string(email.trimmingCharacters(in: .whitespaces)),
                "role": .string(role.rawValue),
            ])
    }

    public static func share(_ list: TodoList, with person: TodoPerson, role: TodoRole) -> TodoOp {
        op("member.set", ["list": .string(list.id), "user": .string(person.userId), "role": .string(role.rawValue)])
    }

    public static func setRole(_ list: TodoList, of member: TodoMember, to role: TodoRole) -> TodoOp {
        op(
            "member.set",
            ["list": .string(list.id), "principal": .string(member.principal), "role": .string(role.rawValue)])
    }

    public static func removeMember(_ list: TodoList, _ member: TodoMember) -> TodoOp {
        op("member.remove", ["list": .string(list.id), "principal": .string(member.principal)])
    }

    // MARK: Tags

    private static func tagUpdate(_ tag: TodoTag, _ set: [String: PaiJSONValue]) -> TodoOp {
        op("tag.update", ["list": .string(tag.listId), "name": .string(tag.name), "set": .object(set)])
    }

    public static func tagRename(_ tag: TodoTag, _ name: String) -> TodoOp? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag.name else { return nil }
        return tagUpdate(tag, ["name": .string(trimmed)])
    }

    /// A colour of the palette, or nil to wear its parent's or the one its name derives.
    public static func tagColor(_ tag: TodoTag, _ color: TodoColor?) -> TodoOp {
        tagUpdate(tag, ["color": color.map { .string($0.rawValue) } ?? .null])
    }

    /// A quiet tag keeps its todos out of views that do not name it.
    public static func tagQuiet(_ tag: TodoTag, _ quiet: Bool) -> TodoOp { tagUpdate(tag, ["quiet": .bool(quiet)]) }

    public static func tagMerge(_ tag: TodoTag, into other: TodoTag) -> TodoOp {
        op("tag.merge", ["list": .string(tag.listId), "from": .string(tag.name), "into": .string(other.name)])
    }

    public static func tagDelete(_ tag: TodoTag) -> TodoOp {
        op("tag.delete", ["list": .string(tag.listId), "name": .string(tag.name)])
    }

    // MARK: Views

    /// A view in or out of the favourites, the sidebar's `togglePinned`.
    public static func favourite(_ view: TodoView, _ pinned: Bool) -> TodoOp {
        viewSave(id: view.id, name: view.name, query: view.query, layout: view.layout, pinned: pinned)
    }

    /// A `view.save` with the three fields the server always wants. On a view that exists the
    /// server keeps every field the op leaves out (symbol, grouping, sorting, defaults); a new
    /// view gets the server's defaults for them.
    ///
    /// `defaults` are what a todo made in the view starts with. Left out, the server answers a
    /// new or default-less view's save with the defaults its query suggests (`proposedDefaults`).
    public static func viewSave(
        id: String, name: String, query: String, layout: String, pinned: Bool? = nil,
        defaults: TodoViewDefaults? = nil
    ) -> TodoOp {
        var fields: [String: PaiJSONValue] = [
            "id": .string(id), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "layout": .string(layout), "query": .string(query.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if let pinned { fields["pinned"] = .bool(pinned) }
        if let defaults, let data = try? JSONEncoder().encode(defaults),
            let value = try? JSONDecoder().decode(PaiJSONValue.self, from: data)
        {
            fields["defaults"] = value
        }
        return op("view.save", fields)
    }

    /// The defaults the server suggests in its answer to a `view.save`, when it suggests any.
    public static func proposedDefaults(_ settlement: TodosSettlement) -> TodoViewDefaults? {
        guard case .applied(let result?) = settlement, let proposed = result.results.first?.defaults,
            !proposed.isEmpty
        else { return nil }
        return proposed
    }

    /// What a view's defaults give a new todo, in words: its tags, its horizon, the desk, today.
    public static func defaultsWords(_ defaults: TodoViewDefaults) -> String {
        var words = (defaults.tags ?? []).map { "#\($0)" }
        if let horizon = defaults.horizon { words.append(TodoHorizonMark.of(horizon).label) }
        if defaults.desk == true { words.append("the desk") }
        if defaults.when == "today" { words.append("today") }
        return words.joined(separator: ", ")
    }

    public static func viewDelete(_ view: TodoView) -> TodoOp { op("view.delete", ["id": .string(view.id)]) }

    /// The op for a row dragged in the list of views (`views` in the order shown, `source` and
    /// `destination` as a list's move reports them), or nil when the row stays where it was.
    public static func viewMove(_ views: [TodoView], from source: Int, to destination: Int) -> TodoOp? {
        guard views.indices.contains(source), destination != source, destination != source + 1 else { return nil }
        let position: TodoPosition =
            destination < views.count ? .before(views[destination].id) : .after(views[views.count - 1].id)
        return op("view.move", ["id": .string(views[source].id), "position": position.json])
    }

    /// The layout a view made on the phone starts with.
    public static let newViewLayout = "list"
}

/// A search kept as a view, the save row of the web's `searchItems`: the view is named by the
/// text as typed and holds the query as the server read it.
public struct TodoSearchSave: Hashable, Sendable {
    public let name: String
    public let query: String

    /// What saving the search on screen would make, or nil when it is not worth keeping: the
    /// answer is for an earlier text, the server could not read all of it or it ends inside a
    /// filter, or it is a bare reference, which names one todo and not a search.
    public static func proposal(_ answer: TodosSearchAnswer?, text: String) -> TodoSearchSave? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = answer?.query, !name.isEmpty, info.raw == text,
            let query = info.normalized?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
            info.issues?.isEmpty != false, info.pending == nil,
            info.tokens?.contains(where: { $0.kind == "ref" }) != true
        else { return nil }
        return TodoSearchSave(name: name, query: query)
    }
}

/// Who may do what to a list's settings and people, the web's `manage/people.ts` and the
/// `ListRow` rules.
public enum TodoListRules {
    /// A shared list the person owns: its name, layout and lock are theirs to change.
    public static func isOwnShared(_ list: TodoList) -> Bool { list.kind == .shared && list.role == .owner }

    /// Its symbol and colour: the owner's, while it takes changes.
    public static func canStyle(_ list: TodoList) -> Bool { list.role == .owner && !list.locked }

    /// Who has access is changed by owners of a shared list only.
    public static func canManageMembers(_ list: TodoList) -> Bool { isOwnShared(list) }

    /// A tag's settings follow the list it lives in.
    public static func canEditTags(in list: TodoList?) -> Bool { list?.role == .owner || list?.role == .editor }

    /// The last owner cannot be removed or demoted.
    public static func isLastOwner(_ member: TodoMember, of list: TodoList) -> Bool {
        member.role == .owner && list.members.filter { $0.role == .owner }.count <= 1
    }

    public static let grantableRoles: [TodoRole] = [.editor, .filer, .viewer, .owner]

    public static func label(_ role: TodoRole) -> String {
        switch role {
        case .owner: "Owner"
        case .editor: "Editor"
        case .filer: "Filer"
        case .viewer: "Viewer"
        case .unrecognized(let raw): raw
        }
    }

    public static func hint(_ role: TodoRole) -> String {
        switch role {
        case .owner: "Manages who has access, and everything an editor can do"
        case .editor: "Adds, changes, completes and moves todos"
        case .filer: "Adds todos and sees only their own"
        case .viewer: "Reads, changes nothing"
        case .unrecognized: ""
        }
    }

    /// The people not on the list yet, by name.
    public static func candidates(_ people: [TodoPerson], for list: TodoList) -> [TodoPerson] {
        let on = Set(list.members.map(\.principal))
        return people.filter { !on.contains($0.principal) }.sorted {
            $0.displayName.localizedCompare($1.displayName) == .orderedAscending
        }
    }

    public static func looksLikeEmail(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression)
            != nil
    }
}

/// Editing the default nudges, the web's `NudgesPanel`: three kinds of up to three entries each;
/// an entry is minutes or hours before a day's time (a timed todo only), or days before at a time
/// of day. Every edit returns the whole object, which is what `prefs.set` replaces.
public enum TodoNudgeDefaultsEdit {
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case timed, day, deadline

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .timed: "A day with a time"
            case .day: "A day without a time"
            case .deadline: "A deadline"
            }
        }

        public var hint: String {
            switch self {
            case .timed: "For a todo that has a day and a time of day."
            case .day: "For a todo that has only a day."
            case .deadline: "For a todo with a deadline."
            }
        }

        /// What a new entry of this kind starts as.
        public var first: TodoDefaultNudges.Entry {
            switch self {
            case .timed: TodoDefaultNudges.Entry(minutes: 15)
            case .day: TodoDefaultNudges.Entry(days: 1, time: "17:00")
            case .deadline: TodoDefaultNudges.Entry(days: 2, time: "17:00")
            }
        }

        /// Only a todo with a time has a time to count minutes from.
        public var allowsMinutes: Bool { self == .timed }
    }

    public enum Unit: String, CaseIterable, Sendable, Identifiable {
        case minutes, hours, days
        public var id: String { rawValue }
    }

    public static let maxEntries = 3
    public static let maxMinutes = 20160
    public static let maxDays = 60

    public static func entries(_ nudges: TodoDefaultNudges, _ kind: Kind) -> [TodoDefaultNudges.Entry] {
        switch kind {
        case .timed: nudges.timed
        case .day: nudges.day
        case .deadline: nudges.deadline
        }
    }

    public static func replacing(
        _ nudges: TodoDefaultNudges, _ kind: Kind, with entries: [TodoDefaultNudges.Entry]
    ) -> TodoDefaultNudges {
        TodoDefaultNudges(
            timed: kind == .timed ? entries : nudges.timed, day: kind == .day ? entries : nudges.day,
            deadline: kind == .deadline ? entries : nudges.deadline)
    }

    public static func adding(_ nudges: TodoDefaultNudges, _ kind: Kind) -> TodoDefaultNudges {
        let current = entries(nudges, kind)
        guard current.count < maxEntries else { return nudges }
        return replacing(nudges, kind, with: current + [kind.first])
    }

    public static func removing(_ nudges: TodoDefaultNudges, _ kind: Kind, at index: Int) -> TodoDefaultNudges {
        var current = entries(nudges, kind)
        guard current.indices.contains(index) else { return nudges }
        current.remove(at: index)
        return replacing(nudges, kind, with: current)
    }

    public static func changing(
        _ nudges: TodoDefaultNudges, _ kind: Kind, at index: Int, to entry: TodoDefaultNudges.Entry
    ) -> TodoDefaultNudges {
        var current = entries(nudges, kind)
        guard current.indices.contains(index) else { return nudges }
        current[index] = entry
        return replacing(nudges, kind, with: current)
    }

    /// The unit an entry is shown in: whole hours read as hours.
    public static func unit(of entry: TodoDefaultNudges.Entry) -> Unit {
        guard let minutes = entry.minutes else { return .days }
        return minutes > 0 && minutes % 60 == 0 ? .hours : .minutes
    }

    public static func amount(of entry: TodoDefaultNudges.Entry) -> Int {
        switch unit(of: entry) {
        case .hours: (entry.minutes ?? 0) / 60
        case .minutes: entry.minutes ?? 0
        case .days: entry.days ?? 0
        }
    }

    /// An entry of `unit` and `amount`, held to what the server takes; a days entry keeps the
    /// time it had, else 17:00.
    public static func entry(
        unit: Unit, amount: Int, keepingTimeOf entry: TodoDefaultNudges.Entry
    ) -> TodoDefaultNudges.Entry {
        switch unit {
        case .days:
            return TodoDefaultNudges.Entry(days: min(maxDays, max(0, amount)), time: entry.time ?? "17:00")
        case .hours: return TodoDefaultNudges.Entry(minutes: min(maxMinutes, max(0, amount * 60)))
        case .minutes: return TodoDefaultNudges.Entry(minutes: min(maxMinutes, max(0, amount)))
        }
    }

    /// The entry in words: "15 minutes before the time", "1 day before at 17:00".
    public static func words(_ entry: TodoDefaultNudges.Entry) -> String {
        let amount = amount(of: entry)
        switch unit(of: entry) {
        case .minutes: return "\(amount) minute\(amount == 1 ? "" : "s") before the time"
        case .hours: return "\(amount) hour\(amount == 1 ? "" : "s") before the time"
        case .days:
            let at = entry.time.map { String($0.prefix(5)) } ?? ""
            return amount == 0 ? "On the day at \(at)" : "\(amount) day\(amount == 1 ? "" : "s") before at \(at)"
        }
    }
}

/// The quick switcher: a view, a list or a tag by a few typed letters, best match first.
public enum TodoSwitcher {
    public enum Kind: String, Sendable { case view, list, tag, settings }

    public struct Hit: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let kind: Kind
        public let identity: TodoIdentity
        /// Where it goes; nil for Settings, which is a screen of its own.
        public let page: TodoPage?
    }

    /// The entry for Todos' own settings, found by its name like a view.
    static let settings = Hit(
        id: "settings", title: "Settings", kind: .settings, identity: TodoIdentity(icon: .repair, color: .slate),
        page: nil)

    /// What a typed query matches, best first: the whole name, then its start, then the start of
    /// a word in it (after a space, `/`, `-` or `_`), then anywhere in it; views before lists
    /// before tags within each. Case and accents do not count. With nothing typed: the favourite
    /// views, then the lists.
    public static func hits(_ browse: TodoBrowse, query: String) -> [Hit] {
        let views = (browse.favourites + browse.moreViews).map { Hit(entry: $0, kind: .view) }
        let lists = browse.lists.map { Hit(entry: $0, kind: .list) }
        let tags = browse.tags.map { Hit(entry: $0, kind: .tag) }
        let needle = fold(query)
        guard !needle.isEmpty else { return browse.favourites.map { Hit(entry: $0, kind: .view) } + lists }
        var ranked: [(rank: Int, order: Int, hit: Hit)] = []
        for (order, hit) in (views + lists + tags + [settings]).enumerated() {
            if let rank = rank(fold(hit.title), needle) { ranked.append((rank, order, hit)) }
        }
        return ranked.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.map(\.hit)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rank(_ name: String, _ needle: String) -> Int? {
        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 1 }
        let separators: Set<Character> = [" ", "/", "-", "_"]
        var index = name.startIndex
        while let found = name[index...].range(of: needle) {
            if found.lowerBound != name.startIndex, separators.contains(name[name.index(before: found.lowerBound)]) {
                return 2
            }
            index = name.index(after: found.lowerBound)
        }
        return name.contains(needle) ? 3 : nil
    }
}

extension TodoSwitcher.Hit {
    init(entry: TodoBrowse.Entry, kind: TodoSwitcher.Kind) {
        self.init(id: entry.id, title: entry.title, kind: kind, identity: entry.identity, page: entry.page)
    }
}
