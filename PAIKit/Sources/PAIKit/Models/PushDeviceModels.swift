import Foundation

/// One of the person's own devices as `GET /api/push/devices` lists it: an iPhone or a browser.
public struct PushDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: PushDeviceKind
    public let name: String
    /// Marks the caller's own iPhone.
    public let thisDevice: Bool
    /// An iPhone's own on/off; a browser is switched off by unsubscribing, so it is always `true`.
    public let pushEnabled: Bool
    public let pausedUntil: String?
    /// An iPhone's daily window; `nil` for a browser and for an iPhone with none.
    public let sleep: PushDeviceSleep?
    public let sleepSkipUntil: String?
    public let mutedChannels: [String]
    public let lastSuccessAt: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, sleep
        case thisDevice = "this_device"
        case pushEnabled = "push_enabled"
        case pausedUntil = "paused_until"
        case sleepSkipUntil = "sleep_skip_until"
        case mutedChannels = "muted_channels"
        case lastSuccessAt = "last_success_at"
    }

    public init(
        id: String, kind: PushDeviceKind, name: String, thisDevice: Bool = false, pushEnabled: Bool = true,
        pausedUntil: String? = nil, sleep: PushDeviceSleep? = nil, sleepSkipUntil: String? = nil,
        mutedChannels: [String] = [], lastSuccessAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.thisDevice = thisDevice
        self.pushEnabled = pushEnabled
        self.pausedUntil = pausedUntil
        self.sleep = sleep
        self.sleepSkipUntil = sleepSkipUntil
        self.mutedChannels = mutedChannels
        self.lastSuccessAt = lastSuccessAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(PushDeviceKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        thisDevice = try c.decodeIfPresent(Bool.self, forKey: .thisDevice) ?? false
        pushEnabled = try c.decodeIfPresent(Bool.self, forKey: .pushEnabled) ?? true
        pausedUntil = try c.decodeIfPresent(String.self, forKey: .pausedUntil)
        sleep = try c.decodeIfPresent(PushDeviceSleep.self, forKey: .sleep)
        sleepSkipUntil = try c.decodeIfPresent(String.self, forKey: .sleepSkipUntil)
        mutedChannels = try c.decodeIfPresent([String].self, forKey: .mutedChannels) ?? []
        lastSuccessAt = try c.decodeIfPresent(String.self, forKey: .lastSuccessAt)
    }

    /// The moment the pause ends, when it has not ended yet at `now`.
    public func pausedUntilDate(after now: Date) -> Date? {
        guard let text = pausedUntil, let date = IsoTimestamp.date(from: text), date > now else { return nil }
        return date
    }
}

public enum PushDeviceKind: WireStringEnum {
    case iphone, browser
    case unrecognized(String)

    public static var knownValues: [String: PushDeviceKind] { ["iphone": .iphone, "browser": .browser] }

    public var wireValue: String {
        switch self {
        case .iphone: "iphone"
        case .browser: "browser"
        case let .unrecognized(raw): raw
        }
    }
}

/// An iPhone's sleep window as the server holds and serves it: `HH:MM` times in the zone named.
public struct PushDeviceSleep: Codable, Sendable, Equatable {
    public let start: String
    public let end: String
    public let tz: String
    /// Whether the window is on now, by the server's own clock and rule.
    public let active: Bool?
    public let skipUntil: String?

    enum CodingKeys: String, CodingKey {
        case start, end, tz, active
        case skipUntil = "skip_until"
    }

    public init(start: String, end: String, tz: String, active: Bool? = nil, skipUntil: String? = nil) {
        self.start = start
        self.end = end
        self.tz = tz
        self.active = active
        self.skipUntil = skipUntil
    }
}

struct PushDevicesResponse: Decodable {
    let devices: [PushDevice]
}

/// What the phone writes about itself on registration: its sleep window (`null` clears it) and the
/// moment "wake early" ends. Sent on every registration so the server holds what the phone holds,
/// and compared against what the server last confirmed so a change is sent once.
public struct DeviceSleepChoice: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public let start: String
        public let end: String
        public let tz: String

        public init(start: String, end: String, tz: String) {
            self.start = start
            self.end = end
            self.tz = tz
        }
    }

    public let window: Window?
    /// ISO 8601 with its offset, `+00:00`.
    public let skipUntil: String?

    public init(window: Window?, skipUntil: String?) {
        self.window = window
        self.skipUntil = skipUntil
    }

    public static let none = DeviceSleepChoice(window: nil, skipUntil: nil)
}

/// A change to one device: any subset. A pause is `null` to end it.
public struct PushDevicePatch: Encodable, Sendable, Equatable {
    public enum Pause: Sendable, Equatable {
        case unchanged
        case until(String)
        case resume
    }

    public var pushEnabled: Bool?
    public var pause: Pause = .unchanged
    public init(pushEnabled: Bool? = nil, pause: Pause = .unchanged) {
        self.pushEnabled = pushEnabled
        self.pause = pause
    }

    enum CodingKeys: String, CodingKey {
        case pushEnabled = "push_enabled"
        case pausedUntil = "paused_until"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pushEnabled, forKey: .pushEnabled)
        switch pause {
        case .unchanged: break
        case .until(let text): try c.encode(text, forKey: .pausedUntil)
        case .resume: try c.encodeNil(forKey: .pausedUntil)
        }
    }
}
