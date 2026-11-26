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
/// geofences, and a place name from the geocoder. Everything that decides whether and what
/// to send is ``LocationReportStore``.
///
/// Created at launch, because a significant location change, a visit or a geofence crossing
/// relaunches a terminated app into the background and the new event reaches only a location
/// manager that already exists. Only the phone the person chose records, and it
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
    /// What waits for the store when an event relaunches the app before it exists.
    private static let pendingLimit = 50

    private enum Pending {
        case fix(LocationFix)
        case visit(VisitSample)
        case region(placeId: String, entered: Bool, at: Date)
    }

    let permission = LocationPermission(access: .undetermined)
    private let manager: CLLocationManager
    private let regions: RegionPlaceMonitor
    private let places: PlaceMonitorController
    private let defaults = UserDefaults.standard
    private var serviceSession: CLServiceSession?
    private var pending: [Pending] = []

    private var store: LocationReportStore? { AppEnvironment.shared.connection?.location }

    private override init() {
        let manager = CLLocationManager()
        let regions = RegionPlaceMonitor(manager: manager)
        self.manager = manager
        self.regions = regions
        places = PlaceMonitorController { regions }
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

    /// Visits and the geofences. iOS keeps monitored regions across launches and delivers their
    /// crossings to this manager's delegate, so a relaunch needs nothing but the manager.
    ///
    /// The geofences are the location manager's region monitoring, not `CLMonitor`:
    /// `CLMonitor.init` raises an uncaught Objective-C assertion in some states of the phone, even
    /// on the first and only open in a process, and Swift cannot catch it: the app dies at launch.
    /// Region monitoring reports every refusal through the delegate instead.
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
        // iOS keeps regions across launches, so ones from an earlier process go too, not only
        // those this process added.
        regions.removeAll()
        Task { await self.places.converge(places: [], versionChanged: false) }
    }

    private func regionCrossed(_ placeId: String, entered: Bool, at date: Date) {
        deliver(.region(placeId: placeId, entered: entered, at: date))
        // The crossing says where the edge is, not where the person is; one fresh fix follows it.
        manager.requestLocation()
    }

    #if DEBUG
        /// What the debug bridge's `/location` reports.
        var debugFacts: [String: String] {
            [
                "access": "\(permission.access)",
                "placesActive": "\(places.isActive)",
                "regions": "\(manager.monitoredRegions.count)",
                "keepsHistory": "\(defaults.bool(forKey: Self.historyKey))",
            ]
        }
    #endif

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

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let placeId = region.identifier
        let date = Date()
        Task { @MainActor in self.regionCrossed(placeId, entered: true, at: date) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let placeId = region.identifier
        let date = Date()
        Task { @MainActor in self.regionCrossed(placeId, entered: false, at: date) }
    }

    /// A region iOS refuses (too many, monitoring unavailable, no permission) goes unwatched; its
    /// crossings never arrive, and nothing else changes.
    nonisolated func locationManager(
        _ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error
    ) {}

    /// `requestLocation()` requires the delegate to implement this; a failed one-shot fix is
    /// retried by the next foreground or significant change.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// The location manager's region monitoring as ``PlaceMonitor``: a place is a circle of its
/// radius, never smaller than iOS reliably detects. The regions are the app's, kept by iOS across
/// launches, so ``identifiers`` includes those an earlier process added.
@MainActor
private final class RegionPlaceMonitor: PlaceMonitor {
    private let manager: CLLocationManager

    init(manager: CLLocationManager) {
        self.manager = manager
    }

    var identifiers: [String] {
        get async { manager.monitoredRegions.map(\.identifier) }
    }

    func add(_ place: MonitoredPlace) async {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
            let spec = PlaceRegion.make(for: place, maximumRadius: manager.maximumRegionMonitoringDistance)
        else { return }
        let center = CLLocationCoordinate2D(latitude: spec.latitude, longitude: spec.longitude)
        guard CLLocationCoordinate2DIsValid(center) else { return }
        let region = CLCircularRegion(center: center, radius: spec.radius, identifier: spec.identifier)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    func remove(_ identifier: String) async {
        for region in manager.monitoredRegions where region.identifier == identifier {
            manager.stopMonitoring(for: region)
        }
    }

    func removeAll() {
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
    }
}
