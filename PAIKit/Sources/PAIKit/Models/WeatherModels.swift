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

/// How much rain an hour holds, by the forecast's amount; the server draws the lines.
public enum RainIntensity: LenientWireEnum {
    case none, light, moderate, heavy
    case unrecognized(String)

    public static let knownValues: [String: RainIntensity] = [
        "none": .none, "light": .light, "moderate": .moderate, "heavy": .heavy,
    ]
}

/// One hour of the 12-hour strip; the first starts now, mid-hour.
public struct WeatherHour: Decodable, Sendable, Equatable {
    public let start: String
    public let chance: Int
    public let precipitationMm: Double?
    public let intensity: RainIntensity

    enum CodingKeys: String, CodingKey {
        case start, chance, intensity
        case precipitationMm = "precipitation_mm"
    }

    public init(start: String, chance: Int, precipitationMm: Double?, intensity: RainIntensity) {
        self.start = start
        self.chance = chance
        self.precipitationMm = precipitationMm
        self.intensity = intensity
    }

    public var startDate: Date? { IsoTimestamp.date(from: start) }
}

/// The next 12 hours: radar nowcast first, then the forecast.
public struct WeatherLater: Decodable, Sendable, Equatable {
    public let chance: Int?
    public let verdict: RainVerdict
    public let at: String?
    public let method: String
    public let reason: WeatherUnknownReason?
    /// Empty from a backend that predates the strip.
    public let hours: [WeatherHour]
    public let heaviestAt: String?
    public let totalMm: Double?

    enum CodingKeys: String, CodingKey {
        case chance, verdict, at, method, reason, hours
        case heaviestAt = "heaviest_at"
        case totalMm = "total_mm"
    }

    public init(
        chance: Int?, verdict: RainVerdict, at: String? = nil, method: String = "radar+forecast",
        reason: WeatherUnknownReason? = nil, hours: [WeatherHour] = [], heaviestAt: String? = nil,
        totalMm: Double? = nil
    ) {
        self.chance = chance
        self.verdict = verdict
        self.at = at
        self.method = method
        self.reason = reason
        self.hours = hours
        self.heaviestAt = heaviestAt
        self.totalMm = totalMm
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chance = try container.decodeIfPresent(Int.self, forKey: .chance)
        verdict = try container.decode(RainVerdict.self, forKey: .verdict)
        at = try container.decodeIfPresent(String.self, forKey: .at)
        method = try container.decode(String.self, forKey: .method)
        reason = try container.decodeIfPresent(WeatherUnknownReason.self, forKey: .reason)
        hours = try container.decodeIfPresent([WeatherHour].self, forKey: .hours) ?? []
        heaviestAt = try container.decodeIfPresent(String.self, forKey: .heaviestAt)
        totalMm = try container.decodeIfPresent(Double.self, forKey: .totalMm)
    }

    public var atDate: Date? { at.flatMap(IsoTimestamp.date(from:)) }
    public var heaviestDate: Date? { heaviestAt.flatMap(IsoTimestamp.date(from:)) }
}

/// The sky as one of eight classes; `night` beside it picks the moon over the sun.
public enum WeatherSymbol: LenientWireEnum {
    case clear, partly, cloudy, fog, rain, sleet, snow, thunder
    case unrecognized(String)

    public static let knownValues: [String: WeatherSymbol] = [
        "clear": .clear, "partly": .partly, "cloudy": .cloudy, "fog": .fog,
        "rain": .rain, "sleet": .sleet, "snow": .snow, "thunder": .thunder,
    ]
}

/// One of the forecast's 12 hours, the first being the current full hour. `temp` is whole
/// degrees Celsius.
public struct WeatherConditionsHour: Decodable, Sendable, Equatable {
    public let start: String
    public let temp: Int
    public let symbol: WeatherSymbol
    public let night: Bool
    public let uv: Double?

    public init(start: String, temp: Int, symbol: WeatherSymbol, night: Bool = false, uv: Double? = nil) {
        self.start = start
        self.temp = temp
        self.symbol = symbol
        self.night = night
        self.uv = uv
    }

    public var startDate: Date? { IsoTimestamp.date(from: start) }
}

/// The UV index now and its highest of the 12 hours; `peakAt` is nil when the peak rounds to 0.
public struct WeatherUv: Decodable, Sendable, Equatable {
    public let now: Double
    public let peak: Double
    public let peakAt: String?

    enum CodingKeys: String, CodingKey {
        case now, peak
        case peakAt = "peak_at"
    }

    public init(now: Double, peak: Double, peakAt: String? = nil) {
        self.now = now
        self.peak = peak
        self.peakAt = peakAt
    }

    public var peakDate: Date? { peakAt.flatMap(IsoTimestamp.date(from:)) }
}

/// One calendar day at the person's location; `date` is that place's own `YYYY-MM-DD`.
public struct WeatherDay: Decodable, Sendable, Equatable {
    public let date: String
    public let symbol: WeatherSymbol
    public let tempMax: Int
    public let tempMin: Int
    /// The highest chance of rain among the day's hours still ahead.
    public let chance: Int?

    enum CodingKeys: String, CodingKey {
        case date, symbol, chance
        case tempMax = "temp_max"
        case tempMin = "temp_min"
    }

    public init(date: String, symbol: WeatherSymbol, tempMax: Int, tempMin: Int, chance: Int? = nil) {
        self.date = date
        self.symbol = symbol
        self.tempMax = tempMax
        self.tempMin = tempMin
        self.chance = chance
    }
}

/// The forecast beside the rain answer. Filled when `reason` is nil; otherwise everything else is
/// nil, false or empty.
public struct WeatherConditions: Decodable, Sendable, Equatable {
    public let reason: WeatherUnknownReason?
    /// The sky over the next 12 hours, never contradicting the rain rows.
    public let symbol: WeatherSymbol?
    public let night: Bool
    public let tempNow: Int?
    public let tempMin: Int?
    public let tempMax: Int?
    public let hours: [WeatherConditionsHour]
    public let uv: WeatherUv?
    public let days: [WeatherDay]

    enum CodingKeys: String, CodingKey {
        case reason, symbol, night, hours, uv, days
        case tempNow = "temp_now"
        case tempMin = "temp_min"
        case tempMax = "temp_max"
    }

    public init(
        reason: WeatherUnknownReason? = nil, symbol: WeatherSymbol? = nil, night: Bool = false,
        tempNow: Int? = nil, tempMin: Int? = nil, tempMax: Int? = nil,
        hours: [WeatherConditionsHour] = [], uv: WeatherUv? = nil, days: [WeatherDay] = []
    ) {
        self.reason = reason
        self.symbol = symbol
        self.night = night
        self.tempNow = tempNow
        self.tempMin = tempMin
        self.tempMax = tempMax
        self.hours = hours
        self.uv = uv
        self.days = days
    }
}

/// `GET /api/weather`.
public struct WeatherResponse: Decodable, Sendable, Equatable {
    public let location: WeatherLocation?
    public let computedAt: String
    public let now: WeatherNow
    public let later: WeatherLater
    public let radarPictureAt: String?
    public let attribution: String
    /// Nil from a server that does not send the forecast.
    public let conditions: WeatherConditions?

    enum CodingKeys: String, CodingKey {
        case location, now, later, attribution, conditions
        case computedAt = "computed_at"
        case radarPictureAt = "radar_picture_at"
    }

    public init(
        location: WeatherLocation?, computedAt: String, now: WeatherNow, later: WeatherLater,
        radarPictureAt: String? = nil, attribution: String, conditions: WeatherConditions? = nil
    ) {
        self.location = location
        self.computedAt = computedAt
        self.now = now
        self.later = later
        self.radarPictureAt = radarPictureAt
        self.attribution = attribution
        self.conditions = conditions
    }

    public var radarPictureDate: Date? { radarPictureAt.flatMap(IsoTimestamp.date(from:)) }

    public var computedDate: Date? { IsoTimestamp.date(from: computedAt) }
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
