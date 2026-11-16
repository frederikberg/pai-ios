import Foundation

/// Swift port of the shapes `pai-cloud` serves for `GET /api/weather` and takes for
/// `POST /api/location`. `pai-cloud` owns this contract; this file mirrors it rather than
/// redefining it.

/// A string-discriminated wire value that decodes a value a newer backend added as
/// `.unrecognized`, so an older build keeps reading the rest of the answer.
public protocol LenientWireEnum: Decodable, Sendable, Hashable {
    static var knownValues: [String: Self] { get }
    static func unrecognized(_ raw: String) -> Self
}

extension LenientWireEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }
}

/// How likely rain is, in the one vocabulary every client shares.
public enum RainVerdict: LenientWireEnum {
    case rain, maybe, unlikely, dry, unknown
    case unrecognized(String)

    public static let knownValues: [String: RainVerdict] = [
        "rain": .rain, "maybe": .maybe, "unlikely": .unlikely, "dry": .dry, "unknown": .unknown,
    ]
}

/// Where the nearest rain is, seen from the person.
public enum RainDirection: LenientWireEnum {
    case north, northEast, east, southEast, south, southWest, west, northWest
    case unrecognized(String)

    public static let knownValues: [String: RainDirection] = [
        "N": .north, "NE": .northEast, "E": .east, "SE": .southEast,
        "S": .south, "SW": .southWest, "W": .west, "NW": .northWest,
    ]

    /// The compass letters the screen shows; an unrecognised value shows as sent.
    public var label: String {
        switch self {
        case let .unrecognized(raw): return raw
        default: return Self.knownValues.first { $0.value == self }?.key ?? ""
        }
    }
}

public enum RainTrend: LenientWireEnum {
    case approaching, passing, leaving
    case unrecognized(String)

    public static let knownValues: [String: RainTrend] = [
        "approaching": .approaching, "passing": .passing, "leaving": .leaving,
    ]
}

/// Why a half of the answer is `unknown`.
public enum WeatherUnknownReason: LenientWireEnum {
    case noLocation, sourceUnavailable
    case unrecognized(String)

    public static let knownValues: [String: WeatherUnknownReason] = [
        "no_location": .noLocation, "source_unavailable": .sourceUnavailable,
    ]
}

/// The stored place the answer was computed for. `recordedAt` stays the server's string and is
/// read through ``IsoTimestamp``.
public struct WeatherLocation: Decodable, Sendable, Equatable {
    public let lat: Double
    public let lon: Double
    public let place: String?
    public let recordedAt: String
    public let accuracyM: Int?
    public let source: String

    enum CodingKeys: String, CodingKey {
        case lat, lon, place, source
        case recordedAt = "recorded_at"
        case accuracyM = "accuracy_m"
    }

    public init(
        lat: Double, lon: Double, place: String?, recordedAt: String, accuracyM: Int?, source: String
    ) {
        self.lat = lat
        self.lon = lon
        self.place = place
        self.recordedAt = recordedAt
        self.accuracyM = accuracyM
        self.source = source
    }

    public var recordedDate: Date? { IsoTimestamp.date(from: recordedAt) }
}

/// The next 60 minutes, from the radar.
public struct WeatherNow: Decodable, Sendable, Equatable {
    public let chance: Int?
    public let verdict: RainVerdict
    public let rainingNow: Bool
    public let startsAt: String?
    public let endsAt: String?
    public let nearestKm: Double?
    public let direction: RainDirection?
    public let trend: RainTrend?
    public let method: String
    public let reason: WeatherUnknownReason?

    enum CodingKeys: String, CodingKey {
        case chance, verdict, direction, trend, method, reason
        case rainingNow = "raining_now"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case nearestKm = "nearest_km"
    }

    public init(
        chance: Int?, verdict: RainVerdict, rainingNow: Bool = false, startsAt: String? = nil,
        endsAt: String? = nil, nearestKm: Double? = nil, direction: RainDirection? = nil,
        trend: RainTrend? = nil, method: String = "radar", reason: WeatherUnknownReason? = nil
    ) {
        self.chance = chance
        self.verdict = verdict
        self.rainingNow = rainingNow
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.nearestKm = nearestKm
        self.direction = direction
        self.trend = trend
        self.method = method
        self.reason = reason
    }

    public var startDate: Date? { startsAt.flatMap(IsoTimestamp.date(from:)) }
    public var endDate: Date? { endsAt.flatMap(IsoTimestamp.date(from:)) }
}

/// The next 12 hours: radar nowcast first, then the forecast.
public struct WeatherLater: Decodable, Sendable, Equatable {
    public let chance: Int?
    public let verdict: RainVerdict
    public let at: String?
    public let method: String
    public let reason: WeatherUnknownReason?

    public init(
        chance: Int?, verdict: RainVerdict, at: String? = nil, method: String = "radar+forecast",
        reason: WeatherUnknownReason? = nil
    ) {
        self.chance = chance
        self.verdict = verdict
        self.at = at
        self.method = method
        self.reason = reason
    }

    public var atDate: Date? { at.flatMap(IsoTimestamp.date(from:)) }
}

/// `GET /api/weather`.
public struct WeatherResponse: Decodable, Sendable, Equatable {
    public let location: WeatherLocation?
    public let computedAt: String
    public let now: WeatherNow
    public let later: WeatherLater
    public let attribution: String

    enum CodingKeys: String, CodingKey {
        case location, now, later, attribution
        case computedAt = "computed_at"
    }

    public init(
        location: WeatherLocation?, computedAt: String, now: WeatherNow, later: WeatherLater,
        attribution: String
    ) {
        self.location = location
        self.computedAt = computedAt
        self.now = now
        self.later = later
        self.attribution = attribution
    }

    public var computedDate: Date? { IsoTimestamp.date(from: computedAt) }
}

/// The body of `POST /api/location`. `source` is always `ios` from this app.
public struct LocationReport: Encodable, Sendable, Equatable {
    public let lat: Double
    public let lon: Double
    public let accuracyM: Int?
    public let place: String?
    public let recordedAt: String
    public let source: String

    enum CodingKeys: String, CodingKey {
        case lat, lon, place, source
        case accuracyM = "accuracy_m"
        case recordedAt = "recorded_at"
    }

    public init(lat: Double, lon: Double, accuracyM: Int?, place: String?, recordedAt: String, source: String = "ios") {
        self.lat = lat
        self.lon = lon
        self.accuracyM = accuracyM
        self.place = place
        self.recordedAt = recordedAt
        self.source = source
    }
}

/// One position fix as the phone's location service delivers it, before anything is decided.
public struct LocationFix: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    /// Horizontal accuracy in metres; negative means the fix is invalid.
    public let accuracy: Double
    public let timestamp: Date

    public init(latitude: Double, longitude: Double, accuracy: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestamp = timestamp
    }
}
