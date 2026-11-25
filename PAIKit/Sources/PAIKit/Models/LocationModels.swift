import Foundation

/// Swift port of the location history contract (`POST /api/location/points`,
/// `GET /api/places/monitor`, `GET /api/location/day`). The latest-position report the weather
/// reads is part of the same write: every point moves it.

/// What a point records. Visits and region events are rows of their own on the server; a fix at
/// the spot of the row before it only extends that row.
public enum LocationPointKind: String, Codable, Sendable, Equatable {
    case fix
    case visitArrive = "visit_arrive"
    case visitDepart = "visit_depart"
    case regionEnter = "region_enter"
    case regionExit = "region_exit"

    /// A plain fix is the only kind that may be dropped when the queue is full: a visit or a
    /// region event is rare and carries meaning.
    public var isDroppable: Bool { self == .fix }
}

/// One point as sent and as queued on the phone. Coordinates carry five decimals, about a metre.
public struct LocationPoint: Codable, Sendable, Equatable {
    public let lat: Double
    public let lon: Double
    public let accuracyM: Int?
    /// ISO 8601 with an offset.
    public let recordedAt: String
    public let kind: LocationPointKind
    /// The named place a region event is about.
    public let placeId: String?
    public let locality: String?

    enum CodingKeys: String, CodingKey {
        case lat, lon, kind, locality
        case accuracyM = "accuracy_m"
        case recordedAt = "recorded_at"
        case placeId = "place_id"
    }

    public init(
        lat: Double, lon: Double, accuracyM: Int?, recordedAt: String, kind: LocationPointKind,
        placeId: String? = nil, locality: String? = nil
    ) {
        self.lat = Self.rounded(lat)
        self.lon = Self.rounded(lon)
        self.accuracyM = accuracyM
        self.recordedAt = recordedAt
        self.kind = kind
        self.placeId = placeId
        self.locality = locality
    }

    /// Five decimals is about a metre; the precision the phone's own fixes carry.
    static func rounded(_ degrees: Double) -> Double {
        (degrees * 100_000).rounded() / 100_000
    }

    /// The wire time of a moment, the one shape the server parses everywhere.
    static func wireTime(_ date: Date) -> String { AlarmTime.wireString(date) }
}

/// The body of `POST /api/location/points`: one to 500 points.
public struct LocationPointsRequest: Encodable, Sendable, Equatable {
    public static let maxPoints = 500

    public let source: String
    public let points: [LocationPoint]

    public init(points: [LocationPoint], source: String = "ios") {
        self.source = source
        self.points = points
    }
}

/// What `POST /api/location/points` answers.
public struct LocationPointsAnswer: Decodable, Sendable, Equatable {
    public let stored: Int
    public let merged: Int
    public let rejected: Int
    /// False for a guest: the latest position moved, nothing is kept.
    public let history: Bool
    /// Changes when the places the phone geofences change; null for a guest.
    public let placesVersion: String?

    enum CodingKeys: String, CodingKey {
        case stored, merged, rejected, history
        case placesVersion = "places_version"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stored = container.decodeLenientInt(forKey: .stored) ?? 0
        merged = container.decodeLenientInt(forKey: .merged) ?? 0
        rejected = container.decodeLenientInt(forKey: .rejected) ?? 0
        history = (try? container.decode(Bool.self, forKey: .history)) ?? false
        placesVersion = try? container.decodeIfPresent(String.self, forKey: .placesVersion)
    }

    public init(stored: Int, merged: Int, rejected: Int, history: Bool, placesVersion: String?) {
        self.stored = stored
        self.merged = merged
        self.rejected = rejected
        self.history = history
        self.placesVersion = placesVersion
    }
}

/// One place the phone geofences: a circle with the server's id.
public struct MonitoredPlace: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let lat: Double
    public let lon: Double
    public let radiusM: Int

    enum CodingKeys: String, CodingKey {
        case id, lat, lon
        case radiusM = "radius_m"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        lat = try container.decode(Double.self, forKey: .lat)
        lon = try container.decode(Double.self, forKey: .lon)
        radiusM = container.decodeLenientInt(forKey: .radiusM) ?? 0
    }

    public init(id: String, lat: Double, lon: Double, radiusM: Int) {
        self.id = id
        self.lat = lat
        self.lon = lon
        self.radiusM = radiusM
    }
}

/// `GET /api/places/monitor`: at most 20 places, the ones live reminders wait on first.
public struct PlacesMonitorAnswer: Decodable, Sendable, Equatable {
    public let places: [MonitoredPlace]
    public let placesVersion: String

    enum CodingKeys: String, CodingKey {
        case places
        case placesVersion = "places_version"
    }

    public init(places: [MonitoredPlace], placesVersion: String) {
        self.places = places
        self.placesVersion = placesVersion
    }
}

/// One stay of a day: the named place holding it, else the device's own name for the spot.
public struct LocationStay: Decodable, Sendable, Equatable {
    public let place: String?
    public let locality: String?
    public let from: String
    public let to: String

    public init(place: String?, locality: String?, from: String, to: String) {
        self.place = place
        self.locality = locality
        self.from = from
        self.to = to
    }
}

/// How much of a day the history covers. `partial` means a gap over six hours between two
/// different places.
public enum LocationCoverage: LenientWireEnum {
    case full, partial, none
    case unrecognized(String)

    public static let knownValues: [String: LocationCoverage] = ["full": .full, "partial": .partial, "none": .none]
}

/// `GET /api/location/day`: one Berlin day of the owner's history.
public struct LocationDay: Decodable, Sendable, Equatable {
    public let date: String
    public let coverage: LocationCoverage
    public let stays: [LocationStay]
    /// Straight lines between recorded points, so a lower bound.
    public let movedKm: Double?
    /// The first and last row of the day, when it has any.
    public let firstAt: String?
    public let lastAt: String?

    enum CodingKeys: String, CodingKey {
        case date, coverage, stays
        case movedKm = "moved_km"
        case firstAt = "first_at"
        case lastAt = "last_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        coverage = (try? container.decode(LocationCoverage.self, forKey: .coverage)) ?? .none
        stays = (try? container.decode([LocationStay].self, forKey: .stays)) ?? []
        movedKm = try? container.decodeIfPresent(Double.self, forKey: .movedKm)
        firstAt = try? container.decodeIfPresent(String.self, forKey: .firstAt)
        lastAt = try? container.decodeIfPresent(String.self, forKey: .lastAt)
    }

    public init(
        date: String, coverage: LocationCoverage, stays: [LocationStay], movedKm: Double?, firstAt: String? = nil,
        lastAt: String? = nil
    ) {
        self.date = date
        self.coverage = coverage
        self.stays = stays
        self.movedKm = movedKm
        self.firstAt = firstAt
        self.lastAt = lastAt
    }
}
