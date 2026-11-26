import Foundation

/// The geofence monitor as ``PlaceMonitorController`` drives it; the app implements it with the
/// location manager's region monitoring.
public protocol PlaceMonitor: Sendable {
    var identifiers: [String] { get async }
    func add(_ place: MonitoredPlace) async
    func remove(_ identifier: String) async
}

/// Keeps one geofence monitor for the life of the process and makes its regions follow whether
/// place monitoring is wanted. Turning monitoring off and on again never opens another one: the
/// first open, finished or still in flight, is shared by every caller and kept, and turning off
/// only removes its regions.
@MainActor
public final class PlaceMonitorController {
    /// Whether the places should be watched. Set synchronously by the caller, so a later
    /// ``converge(places:versionChanged:)`` follows the newest choice whatever order the calls
    /// run in.
    public var isActive = false

    private let open: @MainActor @Sendable () async -> any PlaceMonitor
    private var opening: Task<any PlaceMonitor, Never>?

    /// `open` creates the monitor; it is called at most once.
    public init(open: @escaping @MainActor @Sendable () async -> any PlaceMonitor) {
        self.open = open
    }

    /// Makes the monitor match ``isActive``: active, it watches `places` (opening the monitor on
    /// first use); inactive, it holds no conditions. A monitor never opened is not opened just to
    /// be emptied.
    public func converge(places: [MonitoredPlace], versionChanged: Bool) async {
        guard isActive || opening != nil else { return }
        let monitor = await shared()
        let held = Set(await monitor.identifiers)
        guard isActive else {
            for id in held.sorted() { await monitor.remove(id) }
            return
        }
        let plan = PlaceMonitorPlan.make(desired: places, held: held, versionChanged: versionChanged)
        for id in plan.remove { await monitor.remove(id) }
        for place in plan.add where isActive { await monitor.add(place) }
    }

    private func shared() async -> any PlaceMonitor {
        if let opening { return await opening.value }
        let task = Task { [open] in await open() }
        opening = task
        return await task.value
    }
}
