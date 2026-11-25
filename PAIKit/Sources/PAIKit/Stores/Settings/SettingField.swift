import Foundation

/// A text could not be turned into the value its key holds. Only the shape is judged here (a
/// number, a JSON object); every bound is the server's, which refuses a value with the key and
/// the rule it broke.
public struct SettingFieldProblem: Error, Equatable, Sendable {
    public let message: String
}

/// One registry key as a row: the control its `kind` calls for, what it holds now, and how text
/// typed into it becomes a value. The schema is the server's, so a key the server adds later is
/// drawn by this rule with no change here.
public struct SettingField: Equatable, Sendable, Identifiable {
    /// The controls a row is drawn with.
    public enum Control: Equatable, Sendable {
        /// A switch, saved on change.
        case toggle
        /// A segmented control or a menu over the server's choices, saved on change.
        case choice([String])
        /// A number typed and saved on request.
        case number
        /// A number that can be off: a switch turns it on at the schema's default or off (`null`).
        case optionalNumber
        /// Free text; empty is `null`.
        case text
        /// One entry per line or comma-separated.
        case list
        /// A JSON object; empty is `null`.
        case json
    }

    public let key: String
    public let schema: SettingSchema
    public let value: SettingValue

    public var id: String { key }
    public var label: String { schema.label }
    public var help: String { schema.help }
    public var warning: String? { schema.warning }

    /// `nil` for a kind this build does not know, which no screen can edit.
    public init?(key: String, schema: SettingSchema, value: SettingValue) {
        guard Self.control(for: schema) != nil else { return nil }
        self.key = key
        self.schema = schema
        self.value = value
    }

    public var control: Control {
        Self.control(for: schema) ?? .text
    }

    /// Switches and choices save when changed; text, numbers, lists and JSON when asked.
    public var savesOnChange: Bool {
        switch control {
        case .toggle, .choice: true
        case .number, .optionalNumber, .text, .list, .json: false
        }
    }

    private static func control(for schema: SettingSchema) -> Control? {
        switch schema.kind {
        case .bool: .toggle
        case .enum: .choice(schema.choices ?? [])
        case .int, .float: schema.nullable ? .optionalNumber : .number
        case .string, .uuid: .text
        case .stringList: .list
        case .json: .json
        case .unrecognized: nil
        }
    }

    // MARK: Reading a value

    public var isOn: Bool { value.boolValue ?? false }

    /// The chosen entry of a `choice`.
    public var choice: String { value.stringValue ?? schema.defaultValue.stringValue ?? "" }

    /// What a choice is called: a word in sentence case, an identifier (a model id such as
    /// `eleven_flash_v2_5`) as it is, since changing its spelling would name something else.
    public static func choiceLabel(_ choice: String) -> String {
        choice.contains("_") ? choice : choice.prefix(1).uppercased() + choice.dropFirst()
    }

    /// Whether an optional number is on.
    public var isNumberOn: Bool { !value.isNull }

    /// The value as it is typed into its field.
    public var storedText: String {
        switch value {
        case .null: ""
        case .bool(let flag): flag ? "true" : "false"
        case .number: Self.format(value.doubleValue ?? 0)
        case .string(let text): text
        case .array: (value.stringList ?? []).joined(separator: "\n")
        case .object: Self.formatJSON(value)
        }
    }

    // MARK: Writing a value

    /// What typed text means for this key, or why it means nothing.
    public func parse(_ text: String) -> Result<SettingValue, SettingFieldProblem> {
        switch control {
        case .toggle, .choice:
            return .success(.string(text))
        case .number, .optionalNumber:
            return parseNumber(text)
        case .text:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(trimmed.isEmpty ? .null : .string(trimmed))
        case .list:
            return .success(.array(Self.entries(of: text).map { .string($0) }))
        case .json:
            return Self.parseJSONObject(text)
        }
    }

    /// The value an optional number takes when its switch is turned on.
    public var valueWhenTurnedOn: SettingValue { schema.defaultValue }

    private func parseNumber(_ text: String) -> Result<SettingValue, SettingFieldProblem> {
        let typed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(typed), number.isFinite else {
            return .failure(SettingFieldProblem(message: "Enter a number"))
        }
        if schema.kind == .int {
            guard number.rounded() == number, abs(number) < 9e15 else {
                return .failure(SettingFieldProblem(message: "Enter a whole number"))
            }
            return .success(.whole(Int(number)))
        }
        return .success(.double(number))
    }

    /// A list as typed: one entry per line or comma-separated, blanks dropped.
    static func entries(of text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseJSONObject(_ text: String) -> Result<SettingValue, SettingFieldProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(.null) }
        guard let parsed = try? JSONDecoder().decode(PaiJSONValue.self, from: Data(trimmed.utf8)) else {
            return .failure(SettingFieldProblem(message: "This is not valid JSON"))
        }
        guard case let .object(fields) = parsed else {
            return .failure(SettingFieldProblem(message: "This must be a JSON object, e.g. {\"end_wait_s\": 2}"))
        }
        return .success(fields.isEmpty ? .null : parsed)
    }

    /// Locale-independent, since the text is parsed back with `Double(_:)`, which only accepts a dot.
    private static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    private static func formatJSON(_ value: SettingValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
