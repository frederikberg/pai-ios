import Foundation

/// A visit as the location service reports it, with the "no date" sentinels already resolved:
/// an arrival that was not observed and a departure that has not happened are nil.
public struct VisitSample: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let accuracy: Double
    public let arrival: Date?
    public let departure: Date?

    public init(latitude: Double, longitude: Double, accuracy: Double, arrival: Date?, departure: Date?) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.arrival = arrival
        self.departure = departure
    }
}

/// How what the phone's location service says becomes the points the server keeps.
public enum LocationPointMapping {

    /// A visit is an arrival, a departure, or both, each its own point at the visit's coordinate.
    /// A visit still going on carries no departure and one that began before the phone was
    /// watching carries no arrival, so either may be absent.
    public static func points(for visit: VisitSample, locality: String?) -> [LocationPoint] {
        guard visit.accuracy >= 0 else { return [] }
        let accuracy = Int(visit.accuracy.rounded())
        var points: [LocationPoint] = []
        if let arrival = visit.arrival {
            points.append(
                LocationPoint(
                    lat: visit.latitude, lon: visit.longitude, accuracyM: accuracy,
                    recordedAt: LocationPoint.wireTime(arrival), kind: .visitArrive, locality: locality))
        }
        if let departure = visit.departure {
            points.append(
                LocationPoint(
                    lat: visit.latitude, lon: visit.longitude, accuracyM: accuracy,
                    recordedAt: LocationPoint.wireTime(departure), kind: .visitDepart, locality: locality))
        }
        return points
    }

    /// A plain fix; a negative accuracy is the location service's word for "invalid".
    public static func point(for fix: LocationFix, locality: String?) -> LocationPoint? {
        guard fix.accuracy >= 0 else { return nil }
        return LocationPoint(
            lat: fix.latitude, lon: fix.longitude, accuracyM: Int(fix.accuracy.rounded()),
            recordedAt: LocationPoint.wireTime(fix.timestamp), kind: .fix, locality: locality)
    }

    /// A region event sits at the place's own center: the phone knows it crossed the edge, not
    /// where. The place id is what ties it to the place; no accuracy is claimed.
    public static func point(for place: MonitoredPlace, entered: Bool, at date: Date) -> LocationPoint {
        LocationPoint(
            lat: place.lat, lon: place.lon, accuracyM: nil, recordedAt: LocationPoint.wireTime(date),
            kind: entered ? .regionEnter : .regionExit, placeId: place.id)
    }
}

/// What to do to the phone's geofences so they match the places the server named.
public enum PlaceMonitorPlan {
    /// The most regions iOS lets one app monitor.
    public static let maxPlaces = 20
    /// Regions smaller than this are not reliably detected, so a place is watched at least this wide.
    public static let minimumRadiusMeters = 150

    public struct Plan: Equatable, Sendable {
        /// Places to add, or to add again under the same id to replace their circle.
        public let add: [MonitoredPlace]
        public let remove: [String]
    }

    /// `desired` is in the server's order (places live reminders wait on first), so the cut at the
    /// limit drops the least needed. When the set's version changed every place is added again,
    /// which replaces a moved or resized circle without comparing circles; otherwise only the
    /// missing ones are added. Held ids the server no longer names are removed either way.
    public static func make(desired: [MonitoredPlace], held: Set<String>, versionChanged: Bool) -> Plan {
        let wanted = Array(desired.prefix(maxPlaces))
        let wantedIds = Set(wanted.map(\.id))
        return Plan(
            add: wanted.filter { versionChanged || !held.contains($0.id) },
            remove: held.subtracting(wantedIds).sorted())
    }

    public static func radius(of place: MonitoredPlace) -> Int { max(place.radiusM, minimumRadiusMeters) }
}

/// A place as the circular region the location manager is asked to watch.
public struct PlaceRegion: Equatable, Sendable {
    public let identifier: String
    public let latitude: Double
    public let longitude: Double
    public let radius: Double

    /// The region for `place`, or nil when it is not one the location manager can watch: an empty
    /// id, a coordinate off the globe, or region monitoring unavailable (`maximumRadius` is the
    /// manager's `maximumRegionMonitoringDistance`, negative then). A circle wider than the
    /// manager allows is cut to its maximum rather than refused.
    public static func make(for place: MonitoredPlace, maximumRadius: Double) -> PlaceRegion? {
        guard !place.id.isEmpty,
            place.lat.isFinite, (-90.0...90.0).contains(place.lat),
            place.lon.isFinite, (-180.0...180.0).contains(place.lon),
            maximumRadius.isFinite, maximumRadius > 0
        else { return nil }
        let radius = min(Double(PlaceMonitorPlan.radius(of: place)), maximumRadius)
        return PlaceRegion(identifier: place.id, latitude: place.lat, longitude: place.lon, radius: radius)
    }
}
