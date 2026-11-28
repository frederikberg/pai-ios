import Foundation
import Observation

/// The person's order of apps: one list of app ids with a line in it. The apps before the line are
/// shown directly, the ones after it under "More". The value is the `app_order` person setting,
/// the same on every client; an id a client has no app for is skipped when drawing and kept when
/// the order is written back.
public enum AppOrder {
    /// The entry that ends the apps shown directly.
    public static let line = "---"

    public struct Arranged: Sendable {
        /// Shown directly, in the person's order.
        public let pinned: [AppEntry]
        /// Under "More": the ones named after the line, then whatever the order does not name.
        public let more: [AppEntry]

        public var all: [AppEntry] { pinned + more }
    }

    /// `entries` in the person's order. An order without the line pins everything it names; an
    /// id named on both sides counts as pinned.
    public static func arrange(_ order: [String], _ entries: [AppEntry]) -> Arranged {
        let lineAt = order.firstIndex(of: line)
        let above = unique(lineAt.map { Array(order[..<$0]) } ?? order)
        let below = unique(lineAt.map { Array(order[order.index(after: $0)...]) } ?? [])
        let pinned = above.compactMap { id in entries.first { $0.id == id } }
        let named = below.filter { !above.contains($0) }.compactMap { id in entries.first { $0.id == id } }
        let placed = Set((pinned + named).map(\.id))
        let rest = entries.filter { !placed.contains($0.id) }
        return Arranged(pinned: pinned, more: named + rest)
    }

    /// The setting's value once the person arranged what they see as `sequence` (entry ids with
    /// the line among them). Ids the stored order holds that this client shows nothing for keep
    /// their side of the line, after the ones seen here.
    public static func reordered(stored: [String], sequence: [String]) -> [String] {
        let storedLine = stored.firstIndex(of: line)
        let storedAbove = storedLine.map { Array(stored[..<$0]) } ?? stored
        let storedBelow = storedLine.map { Array(stored[stored.index(after: $0)...]) } ?? []
        let at = sequence.firstIndex(of: line)
        let above = at.map { Array(sequence[..<$0]) } ?? sequence
        let below = at.map { Array(sequence[sequence.index(after: $0)...]) } ?? []
        let unseen: ([String]) -> [String] = { ids in ids.filter { $0 != line && !sequence.contains($0) } }
        return above + unseen(storedAbove) + [line] + below + unseen(storedBelow)
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { $0 != line && seen.insert($0).inserted }
    }
}

/// Where the person was in each app, for as long as the app runs, and whether the Apps list is
/// open. Switching to an app puts back the screens it was left on; an app not visited yet opens
/// on its first screen.
@Observable
public final class AppPlaces {
    /// Whether the Apps list is on show. One flag for every top bar's Apps button.
    public var isShowingApps = false

    @ObservationIgnored private var stacks: [String: [Route]] = [:]

    public init() {}

    /// The path once the person picked `entry` while on `path`.
    ///
    /// The screens of the app being left are kept for its next visit. Every app but the sessions
    /// sits on the start screen, so Back from its first screen leads there; the sessions sit on
    /// the session list, which is the root. `start` is where the app opens when it has no screens
    /// kept, for an app that remembers a place of its own. While asleep nothing is put back that
    /// sleep mode puts away, and the root is the sleep screen.
    public func path(switchingTo entry: AppEntry, start: Route? = nil, from path: [Route], asleep: Bool) -> [Route] {
        let current = AppRegistry.appID(of: path)
        if current == entry.id { return path }
        if let current { stacks[current] = Self.kept(path) }
        var stack = stacks[entry.id] ?? []
        if asleep { stack = Array(stack.prefix { !$0.isSessionSurface }) }
        if entry.id == AppRegistry.sessionsID { return stack }
        if stack.isEmpty {
            guard let first = start ?? entry.route else { return path }
            stack = [first]
        }
        return asleep ? stack : [.apps] + stack
    }

    /// The screens worth coming back to: the path without the start screen under it, up to the
    /// first screen that is a moment rather than a place.
    static func kept(_ path: [Route]) -> [Route] {
        let screens = path.drop { $0 == .apps }
        return Array(screens.prefix { !$0.isMomentary })
    }
}

extension Route {
    /// A screen that is over once it is left: a sheet's stand-in or a running call.
    var isMomentary: Bool {
        switch self {
        case .createSession, .recordings, .computerCall, .apps: true
        default: false
        }
    }

    /// The app a screen belongs to when it is the first of a path, or `nil` for a screen of no app.
    ///
    /// An exhaustive switch with no default, so a route cannot be added without deciding.
    public var appID: String? {
        switch self {
        case .session, .terminal, .createSession, .subagents, .recordings: AppRegistry.sessionsID
        case .notes, .note, .noteContainers, .notePreview: "notes"
        case .arcSpec, .arcSpecList, .arcReport, .arcOverview: "arc"
        case .schedulerList, .schedulerTask, .reminder: "scheduler"
        case .quickActions: "quick-actions"
        case .canteen: "canteen"
        case .alarm: "alarm"
        case .weather: "weather"
        case .me: "me"
        case .cameraImport: "camera-import"
        case .usage: "usage"
        case .decisions: AppRegistry.decisionsID
        case .todos, .todosBrowse, .todosPage, .todosSearch: "todos"
        case .reports, .report: "reports"
        case .browserList, .browser: "browser"
        case .settings, .notifications, .apps, .computerCall: nil
        }
    }
}
