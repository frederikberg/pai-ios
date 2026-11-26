import XCTest

@testable import PAIKit

/// Stands in for the app's monitor, counting opens. Opening takes a moment, so callers overlap it.
@MainActor
private final class FakeMonitors {
    private(set) var opens = 0
    let monitor = FakeMonitor()

    func open() async -> any PlaceMonitor {
        opens += 1
        try? await Task.sleep(nanoseconds: 20_000_000)
        return monitor
    }
}

private actor FakeMonitor: PlaceMonitor {
    private var held: [String: MonitoredPlace] = [:]

    var identifiers: [String] { held.keys.sorted() }
    func add(_ place: MonitoredPlace) { held[place.id] = place }
    func remove(_ identifier: String) { held[identifier] = nil }
}

private let home = MonitoredPlace(id: "home", lat: 50.0, lon: 6.0, radiusM: 200)

@MainActor
final class PlaceMonitorControllerTests: XCTestCase {
    /// Turning history off and on again, and a reconcile overlapping the launch's own start, all
    /// reach one monitor opened once.
    func testStopAndStartAgainNeverOpensASecondMonitor() async {
        let fakes = FakeMonitors()
        let controller = PlaceMonitorController { await fakes.open() }

        controller.isActive = true
        async let launch: Void = controller.converge(places: [home], versionChanged: false)
        controller.isActive = false
        async let stop: Void = controller.converge(places: [], versionChanged: false)
        controller.isActive = true
        async let restart: Void = controller.converge(places: [home], versionChanged: false)
        _ = await (launch, stop, restart)

        controller.isActive = false
        await controller.converge(places: [], versionChanged: false)
        controller.isActive = true
        await controller.converge(places: [home], versionChanged: true)

        XCTAssertEqual(fakes.opens, 1)
        let held = await fakes.monitor.identifiers
        XCTAssertEqual(held, ["home"])
    }

    /// Turning off empties the monitor, and a monitor never opened is not opened just to be emptied.
    func testStopEmptiesTheMonitorWithoutOpeningOne() async {
        let fakes = FakeMonitors()
        let controller = PlaceMonitorController { await fakes.open() }

        await controller.converge(places: [], versionChanged: false)
        XCTAssertEqual(fakes.opens, 0)

        controller.isActive = true
        await controller.converge(places: [home], versionChanged: false)
        let watched = await fakes.monitor.identifiers
        XCTAssertEqual(watched, ["home"])

        controller.isActive = false
        await controller.converge(places: [], versionChanged: false)
        let held = await fakes.monitor.identifiers
        XCTAssertEqual(held, [])
    }
}
