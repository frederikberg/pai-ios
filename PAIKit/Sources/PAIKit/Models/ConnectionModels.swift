import Foundation

/// What `GET /api/settings/connections` answers per outside service. Never a key: only whether
/// one is stored, where it comes from, and the service's status.
public struct ServiceConnection: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let kind: ConnectionKind
    public let baseUrl: String?
    /// The one editable part of the address (Infomaniak's product id), `nil` where there is none.
    public let baseUrlParam: ConnectionAddressPart?
    /// `nil` for a service with no key of ours (the Claude login, MailVerdict).
    public let credential: ConnectionCredential?
    /// Further keys the service takes (the optional read-aloud ElevenLabs key).
    public let extra: [ConnectionExtraKey]
    public let status: ConnectionStatus
    public let statusDetail: String?
    public let note: String?
    public let testable: Bool
    public let usedBy: [ConnectionUse]
    public let spend: ConnectionSpend?

    enum CodingKeys: String, CodingKey {
        case id, label, kind, credential, extra, status, note, testable, spend
        case baseUrl = "base_url"
        case baseUrlParam = "base_url_param"
        case statusDetail = "status_detail"
        case usedBy = "used_by"
    }

    public init(
        id: String, label: String, kind: ConnectionKind, baseUrl: String? = nil,
        baseUrlParam: ConnectionAddressPart? = nil, credential: ConnectionCredential? = nil,
        extra: [ConnectionExtraKey] = [], status: ConnectionStatus = .ok, statusDetail: String? = nil,
        note: String? = nil, testable: Bool = false, usedBy: [ConnectionUse] = [], spend: ConnectionSpend? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.baseUrl = baseUrl
        self.baseUrlParam = baseUrlParam
        self.credential = credential
        self.extra = extra
        self.status = status
        self.statusDetail = statusDetail
        self.note = note
        self.testable = testable
        self.usedBy = usedBy
        self.spend = spend
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(ConnectionKind.self, forKey: .kind)
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl)
        baseUrlParam = try c.decodeIfPresent(ConnectionAddressPart.self, forKey: .baseUrlParam)
        credential = try c.decodeIfPresent(ConnectionCredential.self, forKey: .credential)
        extra = try c.decodeIfPresent([ConnectionExtraKey].self, forKey: .extra) ?? []
        status = try c.decode(ConnectionStatus.self, forKey: .status)
        statusDetail = try c.decodeIfPresent(String.self, forKey: .statusDetail)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        testable = try c.decodeIfPresent(Bool.self, forKey: .testable) ?? false
        usedBy = try c.decodeIfPresent([ConnectionUse].self, forKey: .usedBy) ?? []
        spend = try c.decodeIfPresent(ConnectionSpend.self, forKey: .spend)
    }
}

public enum ConnectionKind: WireStringEnum {
    case model, speech, search, subscription, integration
    case unrecognized(String)

    public static var knownValues: [String: ConnectionKind] {
        [
            "model": .model, "speech": .speech, "search": .search, "subscription": .subscription,
            "integration": .integration,
        ]
    }

    public var wireValue: String {
        switch self {
        case .model: "model"
        case .speech: "speech"
        case .search: "search"
        case .subscription: "subscription"
        case .integration: "integration"
        case let .unrecognized(raw): raw
        }
    }
}

/// `ok` needs nothing, `no_key` has no credential, `tripped` is being skipped by the pipeline,
/// `failing` failed its last test (or its credential cannot be read).
public enum ConnectionStatus: WireStringEnum {
    case ok, noKey, tripped, failing
    case unrecognized(String)

    public static var knownValues: [String: ConnectionStatus] {
        ["ok": .ok, "no_key": .noKey, "tripped": .tripped, "failing": .failing]
    }

    public var wireValue: String {
        switch self {
        case .ok: "ok"
        case .noKey: "no_key"
        case .tripped: "tripped"
        case .failing: "failing"
        case let .unrecognized(raw): raw
        }
    }
}

/// Where a key comes from: stored through the API, the deployment's variable, or nowhere.
public enum CredentialSource: WireStringEnum {
    case stored, environment, none
    case unrecognized(String)

    public static var knownValues: [String: CredentialSource] {
        ["stored": .stored, "environment": .environment, "none": .none]
    }

    public var wireValue: String {
        switch self {
        case .stored: "stored"
        case .environment: "environment"
        case .none: "none"
        case let .unrecognized(raw): raw
        }
    }
}

public struct ConnectionCredential: Codable, Sendable, Equatable {
    /// The stored secret's name, what `PUT/DELETE /api/settings/secrets/{name}` is called with.
    public let secret: String
    public let set: Bool
    public let updatedAt: String?
    public let source: CredentialSource

    enum CodingKeys: String, CodingKey {
        case secret, set, source
        case updatedAt = "updated_at"
    }

    public init(secret: String, set: Bool, updatedAt: String? = nil, source: CredentialSource = .none) {
        self.secret = secret
        self.set = set
        self.updatedAt = updatedAt
        self.source = source
    }
}

public struct ConnectionExtraKey: Codable, Sendable, Equatable {
    public let secret: String
    public let label: String
    public let set: Bool
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case secret, label, set
        case updatedAt = "updated_at"
    }
}

public struct ConnectionAddressPart: Codable, Sendable, Equatable {
    /// The registry key the part is stored under.
    public let key: String
    public let value: String?
    public let source: CredentialSource
}

public struct ConnectionUse: Codable, Sendable, Equatable {
    public let feature: String
    public let label: String
}

/// A model provider's paid calls since its billing cycle began; every figure optional so a
/// provider with no tally reads as no figure rather than as zero.
public struct ConnectionSpend: Codable, Sendable, Equatable {
    public let cycleStart: String?
    public let calls: Int?
    public let costUsd: Double?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let longPromptCalls: Int?
    public let refusals: Int?

    enum CodingKeys: String, CodingKey {
        case calls, refusals
        case cycleStart = "cycle_start"
        case costUsd = "cost_usd"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case longPromptCalls = "long_prompt_calls"
    }
}

struct ConnectionsResponse: Decodable {
    let connections: [ServiceConnection]
}

struct ConnectionResponse: Decodable {
    let connection: ServiceConnection
}

/// What one test call got back. `message` is the service's own words with every credential removed.
public struct ConnectionTestResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let latencyMs: Int
    public let httpStatus: Int?
    public let kind: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case ok, kind, message
        case latencyMs = "latency_ms"
        case httpStatus = "http_status"
    }

    public init(ok: Bool, latencyMs: Int, httpStatus: Int? = nil, kind: String? = nil, message: String? = nil) {
        self.ok = ok
        self.latencyMs = latencyMs
        self.httpStatus = httpStatus
        self.kind = kind
        self.message = message
    }
}
