import Foundation

/// Every built-in action the Quick Actions screen can start. The case order is the order the
/// Actions Library lists them in; where each one sits is ``QuickActionArrangement``.
public enum QuickAction: String, CaseIterable, Sendable {
    case selfReport
    case me
    case computer
    case home
    case ultrafast
    case mailverdict
    case homeCall
    case ultrafastCamera
    case ultrafastCall
    case fastSession
    case fastCall
    case findNote
    case newNote
    case notes
    case alarm
    case weather
    case canteen
    case scheduler
    case decisions
    case usage
    case cameraImport
    case todos
    case newTodo
    case searchTodos
    case todosSwitcher
    case todosDesk
    case pauseNotifications

    /// Actions added after the arrangement learnt to record which actions it has seen: an
    /// arrangement stored before them knows none of them, and they arrive in its More list
    /// instead of hidden.
    static let unrecordedAtFirst: Set<QuickAction> = [
        .todos, .newTodo, .searchTodos, .todosSwitcher, .todosDesk, .pauseNotifications,
    ]

    /// The Apps list entry an action opens, for the actions that only open an app. Its title,
    /// icon, who may open it and whether sleep mode puts it away all come from that entry.
    public var appEntry: AppEntry? {
        let id: String? =
            switch self {
            case .notes: "notes"
            case .alarm: "alarm"
            case .weather: "weather"
            case .canteen: "canteen"
            case .scheduler: "scheduler"
            case .decisions: AppRegistry.decisionsID
            case .usage: "usage"
            case .cameraImport: "camera-import"
            default: nil
            }
        guard let id else { return nil }
        return AppRegistry.all.first { $0.id == id }
    }

    public var title: String {
        switch self {
        case .selfReport: "Self-report"
        case .me: "Me"
        case .computer: "Computer"
        case .home, .homeCall: "Home"
        case .ultrafast, .ultrafastCall: "Ultra-fast"
        case .mailverdict: "Assistant"
        case .ultrafastCamera: "Camera"
        case .fastSession, .fastCall: "Fast"
        case .findNote: "Find note"
        case .newNote: "New note"
        case .todos: "Todos"
        case .newTodo: "New todo"
        case .searchTodos: "Search todos"
        case .todosSwitcher: "Go to"
        case .todosDesk: "Desk"
        case .pauseNotifications: "Pause push"
        case .notes, .alarm, .weather, .canteen, .scheduler, .decisions, .usage, .cameraImport:
            appEntry?.title ?? rawValue
        }
    }

    public var subtitle: String {
        switch self {
        case .selfReport: "Write"
        case .me: "Open"
        case .computer: "Talk"
        case .home, .ultrafast, .fastSession: "Type"
        case .homeCall, .ultrafastCall, .fastCall: "Call"
        case .mailverdict: "MailVerdict"
        case .ultrafastCamera: "Ultra-fast"
        case .findNote: "Filter"
        case .newNote: "Write"
        case .todos: "Open"
        case .newTodo: "Add"
        case .searchTodos: "Find"
        case .todosSwitcher: "View or list"
        case .todosDesk: "In full"
        case .pauseNotifications: "This iPhone"
        case .notes, .alarm, .weather, .canteen, .scheduler, .decisions, .usage, .cameraImport: "Open"
        }
    }

    public var systemImage: String {
        switch self {
        case .selfReport: "leaf.fill"
        case .me: "person.crop.circle.fill"
        case .computer: "waveform.circle.fill"
        case .home: "house.fill"
        case .ultrafast, .ultrafastCall: "hare.fill"
        case .mailverdict: "envelope.fill"
        case .homeCall: "phone.fill"
        case .ultrafastCamera: "camera.fill"
        case .fastSession: "bolt.fill"
        case .fastCall: "phone.badge.waveform.fill"
        case .findNote: "magnifyingglass"
        case .newNote: "square.and.pencil"
        case .todos: "checklist"
        case .newTodo: "plus.circle.fill"
        case .searchTodos: "text.magnifyingglass"
        case .todosSwitcher: "arrow.right.circle.fill"
        case .todosDesk: "pin.fill"
        case .pauseNotifications: "bell.slash.fill"
        case .notes, .alarm, .weather, .canteen, .scheduler, .decisions, .usage, .cameraImport:
            appEntry?.systemImage ?? "app"
        }
    }

    /// Whether the action starts a PAI session. Anything that does can be greyed or badged as a
    /// group, for example while sessions are not wanted.
    public var isSessionAction: Bool {
        switch self {
        case .home, .ultrafast, .homeCall, .ultrafastCall, .ultrafastCamera, .fastSession, .fastCall,
            .mailverdict:
            true
        case .selfReport, .me, .computer, .findNote, .newNote, .notes, .alarm, .weather, .canteen, .scheduler,
            .decisions, .usage, .cameraImport, .todos, .newTodo, .searchTodos, .todosSwitcher, .todosDesk,
            .pauseNotifications:
            false
        }
    }

    /// Whether the action leads into the agents: a session, a call, Computer, or an app sleep mode
    /// puts away. Sleep mode greys these and sends a tap to the sleep screen; the rest keep working.
    ///
    /// An exhaustive switch with no default, so an action cannot be added without deciding.
    public var isNightBlocked: Bool {
        switch self {
        case .computer, .home, .ultrafast, .homeCall, .ultrafastCamera, .ultrafastCall, .fastSession, .fastCall,
            .mailverdict:
            true
        case .selfReport, .me, .findNote, .newNote, .todos, .newTodo, .searchTodos, .todosSwitcher, .todosDesk,
            .pauseNotifications:
            false
        case .notes, .alarm, .weather, .canteen, .scheduler, .decisions, .usage, .cameraImport:
            appEntry?.isNightBlocked ?? false
        }
    }

    /// Whether this person may use the action. Guests have no diary, no Me app and none of the
    /// owner-only apps.
    public func isAvailable(to capabilities: Capabilities) -> Bool {
        switch self {
        case .selfReport, .me: capabilities.canOpenMe
        case .findNote, .newNote: capabilities.canOpenNotes
        case .todos, .newTodo, .searchTodos, .todosSwitcher, .todosDesk: capabilities.canOpenTodos
        default: appEntry.map { $0.isAvailable(capabilities) } ?? true
        }
    }

    /// The session type a session action starts, in the backend's naming. `nil` for the
    /// MailVerdict assistant, which has its own entry, and for everything that starts no session.
    public var sessionType: String? {
        switch self {
        case .home, .homeCall: "home"
        case .ultrafast, .ultrafastCall, .ultrafastCamera: "ultrafast"
        case .fastSession, .fastCall: "fast"
        default: nil
        }
    }

    /// Whether the new session starts as a spoken call rather than typed.
    public var startsCall: Bool {
        switch self {
        case .homeCall, .ultrafastCall, .fastCall: true
        default: false
        }
    }
}

/// A link to another app that the user made: a name and the URL it opens. Kept on this phone only.
public struct QuickActionShortcut: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var urlString: String

    public init(id: UUID = UUID(), name: String, urlString: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
    }

    /// The link to open, or `nil` while it is empty or not a URL with a scheme.
    public var url: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.isEmpty == false else { return nil }
        return url
    }

    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Shortcut" : trimmed
    }

    /// Where the link goes, shown under the name: the host of a web link, the scheme of an app
    /// link (`maps://…` reads as "maps").
    public var subtitle: String {
        guard let url, let scheme = url.scheme?.lowercased() else { return "Set up" }
        if scheme == "http" || scheme == "https" { return url.host ?? scheme }
        return scheme
    }
}

/// One thing that can sit on the grid or in More.
public enum QuickActionItem: Hashable, Sendable {
    case action(QuickAction)
    case shortcut(UUID)
    /// One Todos view or list, chosen when the tile was added: its `TodoPage.key`.
    case todosPage(String)
    /// The tile that opens the More list. Always on the grid, drawn only while More holds something.
    case more

    /// How the item is stored: the action's raw value, `more`, or `shortcut:<uuid>`.
    public var id: String {
        switch self {
        case .action(let action): action.rawValue
        case .shortcut(let id): "shortcut:\(id.uuidString)"
        case .todosPage(let key): "todos-page:\(key)"
        case .more: "more"
        }
    }

    public init?(id: String) {
        if id == "more" {
            self = .more
        } else if id.hasPrefix("shortcut:"), let uuid = UUID(uuidString: String(id.dropFirst("shortcut:".count))) {
            self = .shortcut(uuid)
        } else if id.hasPrefix("todos-page:"), TodoPage(key: String(id.dropFirst("todos-page:".count))) != nil {
            self = .todosPage(String(id.dropFirst("todos-page:".count)))
        } else if let action = QuickAction(rawValue: id) {
            self = .action(action)
        } else {
            return nil
        }
    }

    /// The same as ``id`` without the shortcut's uuid, which changes on every device and run; what
    /// the screenshot run asserts against.
    public var summaryName: String {
        if case .shortcut = self { return "shortcut" }
        return id
    }

    /// Shortcuts open other apps and are never put away at night.
    public var isNightBlocked: Bool {
        if case .action(let action) = self { return action.isNightBlocked }
        return false
    }
}

/// Where an item sits.
public enum QuickActionPlacement: String, CaseIterable, Sendable {
    case grid
    case more
    case hidden

    public var title: String {
        switch self {
        case .grid: "Grid"
        case .more: "More"
        case .hidden: "Hidden"
        }
    }
}

/// The user's Quick Actions: what is on the grid in which order, what is in More in which order,
/// and the shortcuts they made. Everything in the library on neither list is hidden.
public struct QuickActionArrangement: Equatable, Sendable, Codable {
    public var grid: [QuickActionItem]
    public var more: [QuickActionItem]
    public var shortcuts: [QuickActionShortcut]
    /// The Todos views and lists the user added as tiles, by `TodoPage.key`, in the order added.
    public var todosPages: [String]

    public init(
        grid: [QuickActionItem], more: [QuickActionItem], shortcuts: [QuickActionShortcut] = [],
        todosPages: [String] = []
    ) {
        self.grid = grid
        self.more = more
        self.shortcuts = shortcuts
        self.todosPages = todosPages
        normalize()
    }

    /// What a fresh install shows: the agents and the diary up top, notes and a few apps on the
    /// fifth row, the rest in More. Nothing hidden, no shortcuts.
    public static let standard = QuickActionArrangement(
        grid: [
            .action(.selfReport), .action(.me), .more,
            .action(.computer), .action(.home), .action(.ultrafast),
            .action(.mailverdict), .action(.homeCall), .action(.ultrafastCamera),
            .action(.findNote), .action(.newNote), .action(.ultrafastCall),
            .action(.notes), .action(.alarm), .action(.weather),
        ],
        more: [
            .action(.fastSession), .action(.fastCall), .action(.canteen), .action(.scheduler),
            .action(.decisions), .action(.usage), .action(.cameraImport), .action(.todos), .action(.newTodo),
            .action(.searchTodos), .action(.todosSwitcher), .action(.todosDesk), .action(.pauseNotifications),
        ]
    )

    /// Every item there is, in library order: the built-in actions, then the shortcuts in the order
    /// they were made. The More tile is not an item of the library.
    public var library: [QuickActionItem] {
        QuickAction.allCases.map(QuickActionItem.action) + shortcuts.map { .shortcut($0.id) }
            + todosPages.map(QuickActionItem.todosPage)
    }

    public var hidden: [QuickActionItem] {
        let placed = Set(grid + more)
        return library.filter { !placed.contains($0) }
    }

    public func placement(of item: QuickActionItem) -> QuickActionPlacement {
        if grid.contains(item) { return .grid }
        if more.contains(item) { return .more }
        return .hidden
    }

    public func shortcut(_ id: UUID) -> QuickActionShortcut? {
        shortcuts.first { $0.id == id }
    }

    /// Drops what no longer exists and anything listed twice, keeps the More tile on the grid and
    /// only there. What a stored arrangement from another build of the app comes back through.
    mutating func normalize() {
        let known = Set(shortcuts.map(\.id))
        todosPages = todosPages.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let pages = Set(todosPages)
        var seen = Set<QuickActionItem>()
        func keep(_ item: QuickActionItem) -> Bool {
            if case .shortcut(let id) = item, !known.contains(id) { return false }
            if case .todosPage(let key) = item, !pages.contains(key) { return false }
            return seen.insert(item).inserted
        }
        grid = grid.filter(keep)
        more = more.filter { $0 != .more && keep($0) }
        if !grid.contains(.more) { grid.append(.more) }
    }

    private enum CodingKeys: String, CodingKey { case grid, more, shortcuts, todosPages, seen }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Stored as ids, and an id this build does not know (an action that was removed) is
        // dropped rather than failing the whole arrangement.
        let grid = try container.decode([String].self, forKey: .grid).compactMap(QuickActionItem.init(id:))
        var more = try container.decode([String].self, forKey: .more).compactMap(QuickActionItem.init(id:))
        let shortcuts = try container.decode([QuickActionShortcut].self, forKey: .shortcuts)
        let pages = try container.decodeIfPresent([String].self, forKey: .todosPages) ?? []
        // An action the stored arrangement never saw arrives in More, where it is found; one it
        // saw and the person left off both lists stays hidden.
        let seen =
            try container.decodeIfPresent([String].self, forKey: .seen).map { Set($0.compactMap(QuickAction.init)) }
            ?? Set(QuickAction.allCases).subtracting(QuickAction.unrecordedAtFirst)
        for action in QuickAction.allCases where !seen.contains(action) {
            let item = QuickActionItem.action(action)
            if !grid.contains(item) && !more.contains(item) { more.append(item) }
        }
        self.init(grid: grid, more: more, shortcuts: shortcuts, todosPages: pages)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(grid.map(\.id), forKey: .grid)
        try container.encode(more.map(\.id), forKey: .more)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(todosPages, forKey: .todosPages)
        try container.encode(QuickAction.allCases.map(\.rawValue), forKey: .seen)
    }
}

/// The grid's fixed shape: three columns and five rows on screen; a sixth row and beyond is reached
/// by scrolling, and every tile has the same size.
public enum QuickActionGrid {
    public static let columns = 3
    public static let visibleRows = 5

    /// The height of every tile, divided out of the viewport so exactly ``visibleRows`` rows fill
    /// it. Never below `minimum`, so a very short viewport scrolls rather than squashing tiles.
    public static func tileHeight(
        viewportHeight: Double, padding: Double, spacing: Double, minimum: Double = 56
    ) -> Double {
        let rows = Double(visibleRows)
        let divided = (viewportHeight - padding * 2 - spacing * (rows - 1)) / rows
        return max(minimum, divided)
    }
}
