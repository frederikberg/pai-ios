import Foundation

/// Swift port of the Alarm and watch-key shapes `pai-cloud` serves under `/api/alarm` and
/// `/api/watch-keys`. `pai-cloud` owns this contract; this file mirrors it rather than redefining it.

/// Which client created an alarm. An unknown value decodes, so a build older than a new client
/// still lists its alarms.
public enum AlarmSource: Sendable, Hashable {
    case web, ios, watch
    case unrecognized(String)
}

extension AlarmSource: Codable {
    private static let knownValues: [String: AlarmSource] = ["web": .web, "ios": .ios, "watch": .watch]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .web: try container.encode("web")
        case .ios: try container.encode("ios")
        case .watch: try container.encode("watch")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// One armed, one-off alarm. `fireAt` and `createdAt` stay the server's strings and are read
/// through ``IsoTimestamp``.
public struct Alarm: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let fireAt: String
    public let createdAt: String
    public let source: AlarmSource

    enum CodingKeys: String, CodingKey {
        case id, name, source
        case fireAt = "fire_at"
        case createdAt = "created_at"
    }

    public init(id: String, name: String, fireAt: String, createdAt: String, source: AlarmSource) {
        self.id = id
        self.name = name
        self.fireAt = fireAt
        self.createdAt = createdAt
        self.source = source
    }

    public var fireDate: Date? { IsoTimestamp.date(from: fireAt) }
}

/// An alarm that is ringing right now; it leaves the list when it ends.
public struct RingingAlarm: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let fireAt: String
    public let startedAt: String
    public let endsAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case fireAt = "fire_at"
        case startedAt = "started_at"
        case endsAt = "ends_at"
    }

    public init(id: String, name: String, fireAt: String, startedAt: String, endsAt: String) {
        self.id = id
        self.name = name
        self.fireAt = fireAt
        self.startedAt = startedAt
        self.endsAt = endsAt
    }
}

/// `GET /api/alarm`: the armed alarms sorted by `fire_at`, the ringing ones, and the server's
/// clock.
public struct AlarmListResponse: Codable, Sendable, Equatable {
    public let alarms: [Alarm]
    public let ringing: [RingingAlarm]
    public let serverTime: String

    enum CodingKeys: String, CodingKey {
        case alarms, ringing
        case serverTime = "server_time"
    }

    public init(alarms: [Alarm], ringing: [RingingAlarm], serverTime: String) {
        self.alarms = alarms
        self.ringing = ringing
        self.serverTime = serverTime
    }
}

/// `POST /api/alarm` body. `name` is omitted when empty so the server's default applies.
public struct AlarmCreate: Encodable, Sendable, Equatable {
    public let fireAt: String
    public let name: String?
    public let source: AlarmSource

    enum CodingKeys: String, CodingKey {
        case name, source
        case fireAt = "fire_at"
    }

    public init(fireAt: String, name: String? = nil, source: AlarmSource = .ios) {
        self.fireAt = fireAt
        self.name = name
        self.source = source
    }
}

/// One watch key as listed: the secret is never part of it, only a `hint` to tell keys apart.
public struct WatchKey: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let hint: String
    public let createdAt: String
    public let lastUsedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, hint
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    public init(id: String, name: String, hint: String, createdAt: String, lastUsedAt: String?) {
        self.id = id
        self.name = name
        self.hint = hint
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// The answer to creating a key: the one time the plain `key` is ever served.
public struct WatchKeyCreated: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let key: String

    public init(id: String, name: String, key: String) {
        self.id = id
        self.name = name
        self.key = key
    }
}
