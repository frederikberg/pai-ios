import Foundation

/// A value a registry setting holds or is written with. The server's own JSON, so a key this build
/// has never heard of is carried as it arrived.
public typealias SettingValue = PaiJSONValue

extension PaiJSONValue {
    /// A number as a JSON value, spelled the way it was typed rather than as its binary expansion.
    public static func double(_ value: Double) -> PaiJSONValue {
        .number(Decimal(string: String(value)) ?? Decimal(value))
    }

    public static func whole(_ value: Int) -> PaiJSONValue {
        .number(Decimal(value))
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return NSDecimalNumber(decimal: value).doubleValue }
        return nil
    }

    /// The number when it is a whole one.
    public var intValue: Int? {
        guard let double = doubleValue, double.rounded() == double, abs(double) < 9e15 else { return nil }
        return Int(double)
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// A list of strings; `nil` when the value is not one.
    public var stringList: [String]? {
        guard case let .array(items) = self else { return nil }
        var strings: [String] = []
        for item in items {
            guard let text = item.stringValue else { return nil }
            strings.append(text)
        }
        return strings
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// Whose setting a registry key is.
public enum SettingScope: WireStringEnum {
    case person, instance
    case unrecognized(String)

    public static var knownValues: [String: SettingScope] { ["person": .person, "instance": .instance] }

    public var wireValue: String {
        switch self {
        case .person: "person"
        case .instance: "instance"
        case let .unrecognized(raw): raw
        }
    }
}

/// What a registry key holds, which decides the control that edits it.
public enum SettingKind: WireStringEnum {
    case bool, int, float, `enum`, string, stringList, json, uuid
    case unrecognized(String)

    public static var knownValues: [String: SettingKind] {
        [
            "bool": .bool, "int": .int, "float": .float, "enum": .enum, "string": .string,
            "string_list": .stringList, "json": .json, "uuid": .uuid,
        ]
    }

    public var wireValue: String {
        switch self {
        case .bool: "bool"
        case .int: "int"
        case .float: "float"
        case .enum: "enum"
        case .string: "string"
        case .stringList: "string_list"
        case .json: "json"
        case .uuid: "uuid"
        case let .unrecognized(raw): raw
        }
    }
}

/// One registry key as the server declares it (`GET /api/settings`): who owns it, what it may
/// hold, what it is while unset, and the words a screen shows. A client keeps no bound or default
/// of its own.
public struct SettingSchema: Codable, Sendable, Equatable {
    public let scope: SettingScope
    public let kind: SettingKind
    /// What the setting is while unset; the only default there is.
    public let defaultValue: SettingValue
    public let min: Double?
    public let max: Double?
    /// A suggested step for a number control; not enforced.
    public let step: Double?
    /// The accepted values of an `enum`.
    public let choices: [String]?
    public let maxLen: Int?
    public let maxItems: Int?
    public let itemMaxLen: Int?
    public let itemMaxWords: Int?
    /// Whether `null` is a value ("off", "detect", "same as calls") rather than a reset to the default.
    public let nullable: Bool
    public let ownerOnly: Bool
    /// `false` keeps the key off the settings screens.
    public let ui: Bool
    public let label: String
    public let help: String
    /// Shown beside the control when set (the key terms' cost line); the same words on every client.
    public let warning: String?

    enum CodingKeys: String, CodingKey {
        case scope, kind, min, max, step, choices, nullable, ui, label, help, warning
        case defaultValue = "default"
        case maxLen = "max_len"
        case maxItems = "max_items"
        case itemMaxLen = "item_max_len"
        case itemMaxWords = "item_max_words"
        case ownerOnly = "owner_only"
    }

    public init(
        scope: SettingScope = .person, kind: SettingKind, defaultValue: SettingValue = .null,
        min: Double? = nil, max: Double? = nil, step: Double? = nil, choices: [String]? = nil,
        maxLen: Int? = nil, maxItems: Int? = nil, itemMaxLen: Int? = nil, itemMaxWords: Int? = nil,
        nullable: Bool = false, ownerOnly: Bool = false, ui: Bool = true, label: String = "",
        help: String = "", warning: String? = nil
    ) {
        self.scope = scope
        self.kind = kind
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.step = step
        self.choices = choices
        self.maxLen = maxLen
        self.maxItems = maxItems
        self.itemMaxLen = itemMaxLen
        self.itemMaxWords = itemMaxWords
        self.nullable = nullable
        self.ownerOnly = ownerOnly
        self.ui = ui
        self.label = label
        self.help = help
        self.warning = warning
    }

    /// Lenient where a later server may differ: an absent bound is none, and a number that
    /// arrives with a fraction where a whole one was meant is rounded, as Apple's decoder would
    /// otherwise refuse the whole schema over one field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(SettingScope.self, forKey: .scope)
        kind = try c.decode(SettingKind.self, forKey: .kind)
        defaultValue = (try? c.decode(SettingValue.self, forKey: .defaultValue)) ?? .null
        min = try? c.decodeIfPresent(Double.self, forKey: .min)
        max = try? c.decodeIfPresent(Double.self, forKey: .max)
        step = try? c.decodeIfPresent(Double.self, forKey: .step)
        choices = try? c.decodeIfPresent([String].self, forKey: .choices)
        maxLen = c.decodeLenientInt(forKey: .maxLen)
        maxItems = c.decodeLenientInt(forKey: .maxItems)
        itemMaxLen = c.decodeLenientInt(forKey: .itemMaxLen)
        itemMaxWords = c.decodeLenientInt(forKey: .itemMaxWords)
        nullable = (try? c.decode(Bool.self, forKey: .nullable)) ?? false
        ownerOnly = (try? c.decode(Bool.self, forKey: .ownerOnly)) ?? false
        ui = (try? c.decode(Bool.self, forKey: .ui)) ?? true
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        help = (try? c.decode(String.self, forKey: .help)) ?? ""
        warning = try? c.decodeIfPresent(String.self, forKey: .warning)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scope, forKey: .scope)
        try c.encode(kind, forKey: .kind)
        try c.encode(defaultValue, forKey: .defaultValue)
        try c.encodeIfPresent(min, forKey: .min)
        try c.encodeIfPresent(max, forKey: .max)
        try c.encodeIfPresent(step, forKey: .step)
        try c.encodeIfPresent(choices, forKey: .choices)
        try c.encodeIfPresent(maxLen, forKey: .maxLen)
        try c.encodeIfPresent(maxItems, forKey: .maxItems)
        try c.encodeIfPresent(itemMaxLen, forKey: .itemMaxLen)
        try c.encodeIfPresent(itemMaxWords, forKey: .itemMaxWords)
        try c.encode(nullable, forKey: .nullable)
        try c.encode(ownerOnly, forKey: .ownerOnly)
        try c.encode(ui, forKey: .ui)
        try c.encode(label, forKey: .label)
        try c.encode(help, forKey: .help)
        try c.encodeIfPresent(warning, forKey: .warning)
    }
}

/// `GET /api/settings`. A guest's `schema` and `person` hold only the person keys that are not the
/// owner's, and `instance` is `nil`.
public struct SettingsResponse: Codable, Sendable, Equatable {
    public let schema: [String: SettingSchema]
    /// The caller's own values, every visible key present (the default where they never set it).
    public let person: [String: SettingValue]
    public let instance: [String: SettingValue]?

    public init(
        schema: [String: SettingSchema], person: [String: SettingValue], instance: [String: SettingValue]? = nil
    ) {
        self.schema = schema
        self.person = person
        self.instance = instance
    }

    enum CodingKeys: String, CodingKey {
        case schema, person, instance
    }
}
