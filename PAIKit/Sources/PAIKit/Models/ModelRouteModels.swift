import Foundation

/// One step of a feature's route: a provider, a model and an effort (`nil` sends none).
public struct ModelStep: Codable, Sendable, Equatable, Hashable {
    public var provider: String
    public var model: String
    public var effort: String?

    public init(provider: String, model: String, effort: String? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
    }

    /// An absent effort is `null` on the wire, as the route's own body spells it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(effort, forKey: .effort)
    }

    enum CodingKeys: String, CodingKey { case provider, model, effort }
}

/// What a call would do now for one step: whether it would be skipped and why.
public struct ModelChainStep: Codable, Sendable, Equatable {
    public let provider: String
    public let model: String
    public let effort: String?
    public let skippedReason: String?

    enum CodingKeys: String, CodingKey {
        case provider, model, effort
        case skippedReason = "skipped_reason"
    }
}

/// The models a slot may be set to: `provider -> model -> efforts`, where an effort of `nil` is
/// "no effort at all".
public typealias ModelChoices = [String: [String: [String?]]]

/// One feature as `GET /api/settings/models` shows it.
public struct ModelFeature: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// `memory` or `sessions`: how the page groups it.
    public let group: String
    public let editable: Bool
    public let `default`: ModelStep
    public let fallback: ModelStep?
    public let fallbackAllowed: Bool
    public let chainNow: [ModelChainStep]
    public let choices: ModelChoices
    public let fallbackChoices: ModelChoices?

    enum CodingKeys: String, CodingKey {
        case id, label, group, editable, `default`, fallback, choices
        case fallbackAllowed = "fallback_allowed"
        case chainNow = "chain_now"
        case fallbackChoices = "fallback_choices"
    }

    public init(
        id: String, label: String, group: String, editable: Bool = true, default defaultStep: ModelStep,
        fallback: ModelStep? = nil, fallbackAllowed: Bool = true, chainNow: [ModelChainStep] = [],
        choices: ModelChoices, fallbackChoices: ModelChoices? = nil
    ) {
        self.id = id
        self.label = label
        self.group = group
        self.editable = editable
        self.default = defaultStep
        self.fallback = fallback
        self.fallbackAllowed = fallbackAllowed
        self.chainNow = chainNow
        self.choices = choices
        self.fallbackChoices = fallbackChoices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        group = try c.decode(String.self, forKey: .group)
        editable = try c.decodeIfPresent(Bool.self, forKey: .editable) ?? true
        `default` = try c.decode(ModelStep.self, forKey: .default)
        fallback = try c.decodeIfPresent(ModelStep.self, forKey: .fallback)
        fallbackAllowed = try c.decodeIfPresent(Bool.self, forKey: .fallbackAllowed) ?? false
        chainNow = try c.decodeIfPresent([ModelChainStep].self, forKey: .chainNow) ?? []
        choices = try c.decodeIfPresent(ModelChoices.self, forKey: .choices) ?? [:]
        fallbackChoices = try c.decodeIfPresent(ModelChoices.self, forKey: .fallbackChoices)
    }

    /// The line under a row: what a call would do now, with a skipped step said as such.
    public var nowText: String {
        let parts = chainNow.map { step -> String in
            let name = "\(ModelFeature.providerName(step.provider)) \(step.model)"
            return step.skippedReason.map { "\(name) skipped (\($0))" } ?? name
        }
        return parts.isEmpty ? "" : "Now: " + parts.joined(separator: ", then ")
    }

    /// A provider's id as a person reads it.
    public static func providerName(_ id: String) -> String {
        switch id {
        case "anthropic": "Anthropic"
        case "infomaniak": "Infomaniak"
        case "ovhcloud": "OVHcloud"
        case "google": "Google"
        case "elevenlabs": "ElevenLabs"
        case "claude": "Claude"
        default: id
        }
    }
}

struct ModelsResponse: Decodable {
    let features: [ModelFeature]
}

struct ModelFeatureResponse: Decodable {
    let feature: ModelFeature
}

/// What a route is written with.
public struct ModelRouteUpdate: Encodable, Sendable, Equatable {
    public let `default`: ModelStep
    public let fallback: ModelStep?

    public init(default defaultStep: ModelStep, fallback: ModelStep?) {
        self.default = defaultStep
        self.fallback = fallback
    }

    /// A missing fallback is `null`: an omitted key would leave the stored one in force.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`default`, forKey: .default)
        try c.encode(fallback, forKey: .fallback)
    }

    enum CodingKeys: String, CodingKey { case `default`, fallback }
}
