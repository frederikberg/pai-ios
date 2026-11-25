import Foundation

/// One signed-in device or machine identity (`GET /api/sign-ins`). An `app` is one sign-in of a
/// phone app, a `browser` all of a person's browsers, a `machine` a Zitadel machine user (an
/// access key). `active` says whether its latest token is still let in; `current` marks the
/// caller's own row.
public struct SignIn: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: SignInKind
    public let name: String?
    public let clientId: String?
    public let userId: String?
    public let displayName: String?
    public let userAgent: String?
    public let firstSeenAt: String?
    public let lastSeenAt: String?
    public let revokedAt: String?
    public let active: Bool
    public let current: Bool?
    public let agentSlug: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, active, current
        case clientId = "client_id"
        case userId = "user_id"
        case displayName = "display_name"
        case userAgent = "user_agent"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case revokedAt = "revoked_at"
        case agentSlug = "agent_slug"
    }

    public init(
        id: String, active: Bool, current: Bool? = nil, kind: SignInKind = .app, name: String? = nil,
        clientId: String? = nil, userId: String? = nil, displayName: String? = nil, userAgent: String? = nil,
        firstSeenAt: String? = nil, lastSeenAt: String? = nil, revokedAt: String? = nil, agentSlug: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.clientId = clientId
        self.userId = userId
        self.displayName = displayName
        self.userAgent = userAgent
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
        self.active = active
        self.current = current
        self.agentSlug = agentSlug
    }
}

public enum SignInKind: WireStringEnum {
    case app, browser, machine
    case unrecognized(String)

    public static var knownValues: [String: SignInKind] {
        ["app": .app, "browser": .browser, "machine": .machine]
    }

    public var wireValue: String {
        switch self {
        case .app: "app"
        case .browser: "browser"
        case .machine: "machine"
        case let .unrecognized(raw): raw
        }
    }
}

/// `GET /api/watch-keys?everyone=true` (owner only): one key of anyone, naming whose.
public struct PersonWatchKey: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let hint: String
    public let createdAt: String
    public let lastUsedAt: String?
    public let userId: String
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, hint
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case userId = "user_id"
        case displayName = "display_name"
    }

    public init(
        id: String, name: String, hint: String, createdAt: String, lastUsedAt: String?, userId: String,
        displayName: String?
    ) {
        self.id = id
        self.name = name
        self.hint = hint
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.userId = userId
        self.displayName = displayName
    }
}
