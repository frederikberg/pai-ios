import CoreLocation
import Observation
import PAIKit
import UIKit

/// What the person has allowed this app to do with location, as the Settings section shows it.
@MainActor
@Observable
final class LocationPermission {
    enum Access {
        case undetermined, denied, whenInUse, always
    }

    fileprivate(set) var access: Access

    init(access: Access) {
        self.access = access
    }
}

/// The Apple-only half of location reporting: permissions, the location manager, visits, the
/// geofence monitor, and a place name from the geocoder. Everything that decides whether and what
/// to send is ``LocationReportStore``.
///
/// Created at launch, because a significant location change, a visit or a geofence crossing
/// relaunches a terminated app into the background and the new event reaches only a location
/// manager (or a monitor) that already exists. Only the phone the person chose records, and it
/// prefers what costs the least battery: significant-change monitoring (cell and Wi-Fi, about
/// 500 m and not more than every 5 minutes), visits (arrival and departure from the motion
/// coprocessor) and region monitoring of the owner's named places, plus one fix each time the app
/// comes to the front. Nothing here runs continuous updates.
@MainActor
final class LocationReporter: NSObject, CLLocationManagerDelegate {
    static let shared = LocationReporter()

    private static let monitoringKey = "locationMonitoring"
    private static let historyKey = "locationKeepsHistory"
    private static let askedAlwaysKey = "locationAskedForAlways"
    private static let monitorName = "pai-places"
    /// What waits for the store when an event relaunches the app before it exists.
    private static let pendingLimit = 50

    private enum Pending {
        case fix(LocationFix)
        case visit(VisitSample)
        case region(placeId: String, entered: Bool, at: Date)
    }

    let permission = LocationPermission(access: .undetermined)
    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private lazy var places = PlaceMonitorController { [weak self] in
        await Self.openMonitor { [weak self] event in self?.handle(event) }
    }
    private var serviceSession: CLServiceSession?
    private var pending: [Pending] = []

    private var store: LocationReportStore? { AppEnvironment.shared.connection?.location }

    private override init() {
        super.init()
        permission.access = Self.access(for: manager.authorizationStatus)
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // A relaunch from a location event only delivers it to a manager that is monitoring again.
        if defaults.bool(forKey: Self.monitoringKey) { startMonitoring() }
        if defaults.bool(forKey: Self.historyKey) { startHistoryMonitoring() }
    }

    /// Brings monitoring and permissions in line with the person's choice. Called once the
    /// settings are read and whenever the "Use this iPhone for location" switch changes.
    func reconcile() {
        guard let store, store.usesThisDevice else {
            stopMonitoring()
            stopHistoryMonitoring()
            return
        }
        store.syncRole()
        store.onPlacesChange = { [weak self] places, changed in
            Task { @MainActor in await self?.places.converge(places: places, versionChanged: changed) }
        }
        drainPending(into: store)
        switch permission.access {
        case .undetermined:
            manager.requestWhenInUseAuthorization()
        case .whenInUse:
            // The Always upgrade is asked for once; iOS decides when its own prompt appears.
            if !defaults.bool(forKey: Self.askedAlwaysKey) {
                defaults.set(true, forKey: Self.askedAlwaysKey)
                manager.requestAlwaysAuthorization()
            }
            startMonitoring()
        case .always:
            startMonitoring()
        case .denied:
            stopMonitoring()
        }
        // Visits and geofences are the owner's, and iOS delivers them in the background only with
        // Always access.
        if store.keepsHistory, permission.access == .always {
            startHistoryMonitoring()
            Task { await store.refreshPlaces() }
        } else {
            stopHistoryMonitoring()
        }
    }

    /// One fresh fix, asked for whenever the app comes to the front on the chosen phone; what the
    /// phone could not send while it was away goes out and the places to watch are read again.
    func foregroundFix() {
        guard store?.usesThisDevice == true else { return }
        if let store {
            Task {
                await store.flush()
                await store.refreshPlaces()
            }
        }
        guard permission.access == .whenInUse || permission.access == .always else { return }
        manager.requestLocation()
    }

    /// The locality at a coordinate, kept within the server's limit for a place name.
    nonisolated static func placeName(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let name = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.name
        return name.map { String($0.prefix(80)) }
    }

    // MARK: Monitoring

    private func startMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        defaults.set(true, forKey: Self.monitoringKey)
        manager.startMonitoringSignificantLocationChanges()
    }

    private func stopMonitoring() {
        defaults.set(false, forKey: Self.monitoringKey)
        manager.stopMonitoringSignificantLocationChanges()
    }

    /// Visits and the geofence monitor. The monitor is a named object whose conditions iOS keeps
    /// across launches; opening it by name and reading its events is what a relaunch needs. It is
    /// opened once per process (``PlaceMonitorController``), never again after a stop.
    private func startHistoryMonitoring() {
        defaults.set(true, forKey: Self.historyKey)
        manager.startMonitoringVisits()
        if serviceSession == nil { serviceSession = CLServiceSession(authorization: .always) }
        places.isActive = true
        Task { await self.places.converge(places: self.store?.monitoredPlaces ?? [], versionChanged: false) }
    }

    private func stopHistoryMonitoring() {
        defaults.set(false, forKey: Self.historyKey)
        manager.stopMonitoringVisits()
        serviceSession?.invalidate()
        serviceSession = nil
        places.isActive = false
        Task { await self.places.converge(places: [], versionChanged: false) }
    }

    /// Opens the named monitor and reads its events for the rest of the process. If the sequence
    /// ends, events stop until the next launch: opening the name again would trap.
    private static func openMonitor(onEvent: @escaping @MainActor @Sendable (CLMonitor.Event) -> Void) async
        -> any PlaceMonitor
    {
        let monitor = await CLMonitor(monitorName)
        Task { @MainActor in
            do {
                for try await event in await monitor.events { onEvent(event) }
            } catch {}
        }
        return CoreLocationPlaceMonitor(monitor: monitor)
    }

    private func handle(_ event: CLMonitor.Event) {
        let entered: Bool
        switch event.state {
        case .satisfied: entered = true
        case .unsatisfied: entered = false
        default: return
        }
        deliver(.region(placeId: event.identifier, entered: entered, at: event.date))
        // The crossing says where the edge is, not where the person is; one fresh fix follows it.
        manager.requestLocation()
    }

    // MARK: Delivery

    private func deliver(_ item: Pending) {
        guard let store else {
            if pending.count < Self.pendingLimit { pending.append(item) }
            return
        }
        send(item, to: store)
    }

    private func drainPending(into store: LocationReportStore) {
        let waiting = pending
        pending = []
        for item in waiting { send(item, to: store) }
    }

    private func send(_ item: Pending, to store: LocationReportStore) {
        Task {
            switch item {
            case .fix(let fix): await store.report(fix)
            case .visit(let visit): await store.recordVisit(visit)
            case .region(let placeId, let entered, let date):
                await store.recordRegion(placeId: placeId, entered: entered, at: date)
            }
        }
    }

    private static func access(for status: CLAuthorizationStatus) -> LocationPermission.Access {
        switch status {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        case .denied, .restricted: .denied
        default: .undetermined
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.permission.access = Self.access(for: status)
            self.reconcile()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let fix = LocationFix(
            latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude,
            accuracy: latest.horizontalAccuracy, timestamp: latest.timestamp)
        Task { @MainActor in self.deliver(.fix(fix)) }
    }

    /// A visit carries `distantPast` for an arrival nobody saw and `distantFuture` while it is still
    /// going on; both mean "no date" and become nil.
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let sample = VisitSample(
            latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude,
            accuracy: visit.horizontalAccuracy,
            arrival: visit.arrivalDate == .distantPast ? nil : visit.arrivalDate,
            departure: visit.departureDate == .distantFuture ? nil : visit.departureDate)
        Task { @MainActor in self.deliver(.visit(sample)) }
    }

    /// `requestLocation()` requires the delegate to implement this; a failed one-shot fix is
    /// retried by the next foreground or significant change.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// Core Location's monitor as ``PlaceMonitor``: a place is a circle of its radius, never smaller
/// than iOS reliably detects.
private final class CoreLocationPlaceMonitor: PlaceMonitor {
    let monitor: CLMonitor

    init(monitor: CLMonitor) {
        self.monitor = monitor
    }

    var identifiers: [String] {
        get async { await monitor.identifiers }
    }

    func add(_ place: MonitoredPlace) async {
        let center = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
        let radius = CLLocationDistance(PlaceMonitorPlan.radius(of: place))
        await monitor.add(CLMonitor.CircularGeographicCondition(center: center, radius: radius), identifier: place.id)
    }

    func remove(_ identifier: String) async {
        await monitor.remove(identifier)
    }
}
