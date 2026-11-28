import Foundation

/// One app in the Apps list: what it is called, where it leads, who may open it, and whether sleep
/// mode puts it away.
public struct AppEntry: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// The app's first screen; `nil` for the sessions, whose first screen is the root.
    public let route: Route?
    /// Whether this person may open it.
    public let isAvailable: @Sendable (Capabilities) -> Bool
    /// Whether sleep mode puts it away. A session surface unless an entry says otherwise, so a new
    /// app is classified by the one decision its route already needs (``Route/isSessionSurface``).
    public let isNightBlocked: Bool

    public init(
        id: String, title: String, systemImage: String, route: Route?,
        isAvailable: @escaping @Sendable (Capabilities) -> Bool = { _ in true }, isNightBlocked: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.route = route
        self.isAvailable = isAvailable
        self.isNightBlocked = isNightBlocked ?? route?.isSessionSurface ?? true
    }
}

/// Every app the app offers, in the order a person who arranged nothing gets. The Apps list, the
/// start screen and the sleep screen are all drawn from it in the person's order (``AppOrder``),
/// so an app added here appears on each with no further edit, and sleep mode keeps it off its
/// screen only when its route is one of the agents' surfaces.
public enum AppRegistry {
    public static let decisionsID = "decisions"
    public static let sessionsID = "sessions"

    public static let all: [AppEntry] = [
        AppEntry(id: sessionsID, title: "Sessions", systemImage: "bubble.left.and.bubble.right", route: nil),
        AppEntry(id: "quick-actions", title: "Quick Actions", systemImage: "square.grid.2x2", route: .quickActions),
        AppEntry(id: "me", title: "Me", systemImage: "leaf.fill", route: .me, isAvailable: { $0.canOpenMe }),
        AppEntry(
            id: "todos", title: "Todos", systemImage: "checklist", route: .todos, isAvailable: { $0.canOpenTodos }),
        AppEntry(
            id: "arc", title: "Arc", systemImage: "shippingbox", route: .arcSpecList, isAvailable: { $0.canOpenArc }),
        AppEntry(
            id: "notes", title: "Notes", systemImage: "note.text", route: .notes, isAvailable: { $0.canOpenNotes }),
        AppEntry(
            id: "scheduler", title: "Scheduler", systemImage: "clock.badge.checkmark", route: .schedulerList,
            isAvailable: { $0.canOpenScheduler }),
        AppEntry(id: "alarm", title: "Alarm", systemImage: "alarm", route: .alarm, isAvailable: { $0.canOpenAlarm }),
        AppEntry(
            id: "weather", title: "Weather", systemImage: "cloud.rain", route: .weather,
            isAvailable: { $0.canOpenWeather }),
        AppEntry(
            id: "canteen", title: "Canteen", systemImage: "fork.knife", route: .canteen,
            isAvailable: { $0.canOpenCanteen }),
        // No capability: it reads the phone's own files and writes its own photo library, so the
        // server has nothing to admit or refuse.
        AppEntry(id: "camera-import", title: "Camera Import", systemImage: "camera.on.rectangle", route: .cameraImport),
        AppEntry(id: "usage", title: "Usage", systemImage: "gauge.with.dots.needle.33percent", route: .usage),
        AppEntry(
            id: decisionsID, title: "Decisions", systemImage: "checklist", route: .decisions,
            isAvailable: { $0.canOpenDecisions }),
        AppEntry(
            id: "reports", title: "Reports", systemImage: "doc.richtext", route: .reports,
            isAvailable: { $0.canOpenReports }),
        AppEntry(
            id: "browser", title: "Browser", systemImage: "globe", route: .browserList,
            isAvailable: { $0.canOpenBrowser }),
    ]

    /// What the Apps list shows this person.
    public static func listed(for capabilities: Capabilities, in entries: [AppEntry] = all) -> [AppEntry] {
        entries.filter { $0.isAvailable(capabilities) }
    }

    /// What the Apps sheet shows: the whole list, or the night's while sleep mode is on.
    public static func visible(for capabilities: Capabilities, asleep: Bool, in entries: [AppEntry] = all)
        -> [AppEntry]
    {
        asleep ? listedAtNight(for: capabilities, in: entries) : listed(for: capabilities, in: entries)
    }

    /// What the sleep screen shows this person: the Apps list without the apps sleep mode puts away.
    public static func listedAtNight(for capabilities: Capabilities, in entries: [AppEntry] = all) -> [AppEntry] {
        listed(for: capabilities, in: entries).filter { !$0.isNightBlocked }
    }

    /// The apps this person can open right now, in their order: the ones shown directly and the
    /// ones under "More". While asleep, without the apps sleep mode puts away.
    public static func arranged(
        for capabilities: Capabilities, order: [String], asleep: Bool, in entries: [AppEntry] = all
    ) -> AppOrder.Arranged {
        AppOrder.arrange(order, visible(for: capabilities, asleep: asleep, in: entries))
    }

    /// The app the person is in on `path`: the app of its first screen above the start screen.
    /// The root is the sessions; the start screen alone, or a screen of no app, is `nil`.
    public static func appID(of path: [Route]) -> String? {
        guard let first = path.first(where: { $0 != .apps }) else { return path.isEmpty ? sessionsID : nil }
        return first.appID
    }
}
