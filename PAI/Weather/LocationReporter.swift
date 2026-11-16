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

/// The Apple-only half of location reporting: permissions, the location manager, and a place name
/// from the geocoder. Everything that decides whether and what to send is ``LocationReportStore``.
///
/// Created at launch, because a significant location change relaunches a terminated app into the
/// background and the new event reaches only a location manager that already has its delegate.
/// Only the phone the person chose monitors: significant-change monitoring (cell and Wi-Fi, about
/// 500 m and not more than every 5 minutes) plus one fix each time the app comes to the front.
@MainActor
final class LocationReporter: NSObject, CLLocationManagerDelegate {
    static let shared = LocationReporter()

    private static let monitoringKey = "locationMonitoring"
    private static let askedAlwaysKey = "locationAskedForAlways"

    let permission = LocationPermission(access: .undetermined)
    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard

    private var store: LocationReportStore? { AppEnvironment.shared.connection?.location }

    private override init() {
        super.init()
        permission.access = Self.access(for: manager.authorizationStatus)
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // A relaunch from a location event only delivers it to a manager that is monitoring again.
        if defaults.bool(forKey: Self.monitoringKey) { startMonitoring() }
    }

    /// Brings monitoring and permissions in line with the person's choice. Called once the
    /// settings are read and whenever the "Use this iPhone for weather" switch changes.
    func reconcile() {
        guard store?.usesThisDevice == true else {
            stopMonitoring()
            return
        }
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
    }

    /// One fresh fix, asked for whenever the app comes to the front on the chosen phone.
    func foregroundFix() {
        guard store?.usesThisDevice == true, permission.access == .whenInUse || permission.access == .always
        else { return }
        manager.requestLocation()
    }

    /// The locality at a coordinate, kept within the server's limit for a place name.
    nonisolated static func placeName(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let name = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.name
        return name.map { String($0.prefix(80)) }
    }

    private func startMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        defaults.set(true, forKey: Self.monitoringKey)
        manager.startMonitoringSignificantLocationChanges()
    }

    private func stopMonitoring() {
        defaults.set(false, forKey: Self.monitoringKey)
        manager.stopMonitoringSignificantLocationChanges()
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
        Task { @MainActor in
            guard let store = self.store else { return }
            await store.report(fix)
        }
    }

    /// `requestLocation()` requires the delegate to implement this; a failed one-shot fix is
    /// retried by the next foreground or significant change.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
