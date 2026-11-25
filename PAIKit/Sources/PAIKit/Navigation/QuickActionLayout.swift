import Foundation

/// Everything the Quick Actions screen can start, in the order the overflow list shows them.
///
/// The case order is the single list of actions: ``QuickActionLayout/grid`` places some of them on
/// the screen, and every case it leaves out is offered by the More tile. A new case that is not
/// placed on the grid therefore appears in More with no further edit.
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
    case shortcut1
    case shortcut2
    case shortcut3

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
        case .shortcut1, .shortcut2, .shortcut3: "Shortcut"
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
        case .shortcut1, .shortcut2, .shortcut3: "Todoist"
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
        case .shortcut1, .shortcut2, .shortcut3: "checklist"
        }
    }

    /// Whether the action starts a PAI session. Anything that does can be greyed or badged as a
    /// group, for example while sessions are not wanted.
    public var isSessionAction: Bool {
        switch self {
        case .home, .ultrafast, .homeCall, .ultrafastCall, .ultrafastCamera, .fastSession, .fastCall,
            .mailverdict:
            true
        case .selfReport, .me, .computer, .findNote, .newNote, .shortcut1, .shortcut2, .shortcut3:
            false
        }
    }

    /// Whether the action leads into the agents: a session, a call, Computer. Sleep mode greys
    /// these and sends a tap to the sleep screen; the rest keep working.
    ///
    /// An exhaustive switch with no default, so an action cannot be added without deciding.
    public var isNightBlocked: Bool {
        switch self {
        case .computer, .home, .ultrafast, .homeCall, .ultrafastCamera, .ultrafastCall, .fastSession, .fastCall,
            .mailverdict:
            true
        case .selfReport, .me, .findNote, .newNote, .shortcut1, .shortcut2, .shortcut3:
            false
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

    /// The slot number (1...3) of a configurable shortcut.
    public var shortcutSlot: Int? {
        switch self {
        case .shortcut1: 1
        case .shortcut2: 2
        case .shortcut3: 3
        default: nil
        }
    }
}

/// One cell of the Quick Actions grid.
public enum QuickActionSlot: Equatable, Sendable {
    case action(QuickAction)
    /// Opens the list of actions the grid has no room for.
    case more
    case empty
}

/// Where each action sits on the screen. Three columns, so a tile's position is learnable; the
/// More tile is fixed at the top right.
public enum QuickActionLayout {
    public static let columns = 3

    public static let grid: [[QuickActionSlot]] = [
        [.action(.selfReport), .action(.me), .more],
        [.action(.computer), .action(.home), .action(.ultrafast)],
        [.action(.mailverdict), .action(.homeCall), .action(.ultrafastCamera)],
        [.empty, .empty, .action(.ultrafastCall)],
    ]

    /// Every action the grid does not place, in the order of ``QuickAction/allCases``.
    public static var overflow: [QuickAction] {
        let placed = Set(
            grid.flatMap { $0 }.compactMap { slot -> QuickAction? in
                if case .action(let action) = slot { return action }
                return nil
            })
        return QuickAction.allCases.filter { !placed.contains($0) }
    }

    /// The grid as one line, rows split by `|` and cells by `,` (`more` and `-` for the More tile
    /// and an empty cell), for the screenshot run to assert against the app's own layout.
    public static var summary: String {
        grid.map { row in
            row.map { slot -> String in
                switch slot {
                case .action(let action): action.rawValue
                case .more: "more"
                case .empty: "-"
                }
            }.joined(separator: ",")
        }.joined(separator: "|")
    }
}
