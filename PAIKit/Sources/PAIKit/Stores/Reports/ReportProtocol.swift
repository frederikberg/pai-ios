import Foundation

/// A message the page posted to its host.
public enum ReportPageMessage: Equatable, Sendable {
    /// The page's script runs and listens for `init`.
    case ready
    /// The page's whole answers object after a change.
    case answers([String: PaiJSONValue])
    /// The reader pressed "Add to message": the text goes into the session's composer, unsent.
    case addToMessage(String)
    /// How far the reader has scrolled, in the page's own pixels.
    case position(Double)
    /// The page's answers as the text a message carries, and how many decisions are answered.
    case answersText(ReportAnswersText)
}

/// What a page says its answers are as message text (`answers-text`).
public struct ReportAnswersText: Equatable, Sendable {
    public let text: String
    public let answered: Int
    public let total: Int

    public init(text: String, answered: Int, total: Int) {
        self.text = text
        self.answered = answered
        self.total = total
    }
}

/// The postMessage protocol between a report's page and the app, as
/// `docs/architecture/dynamic-reports.md` in pai-cloud defines it and
/// `web/src/apps/reports/reportProtocol.ts` implements it. This file is its Swift twin: `parse` is
/// `parseFromPage`, `initMessage` is `toPageMessage({type: 'init'})`, `appendToDraft` is the same
/// function of the same name.
///
/// Every message is a JSON object `{protocol: "pai-report", version: 1, type, ...}`. The page is
/// never trusted, so anything that is not a well-formed message of this protocol is `nil`.
public enum ReportProtocol {
    public static let name = "pai-report"
    public static let version = 1

    /// The longest text a page may put into the composer (the draft's own ceiling).
    public static let addToMessageMaxCharacters = 100_000

    /// A message the page posted, or `nil` when it is not a well-formed one of this protocol.
    public static func parse(json: String) -> ReportPageMessage? {
        guard let data = json.data(using: .utf8),
            case .object(let object)? = try? JSONDecoder().decode(PaiJSONValue.self, from: data),
            case .string(name)? = object["protocol"], case .number(let number)? = object["version"],
            number == Decimal(version), case .string(let type)? = object["type"]
        else { return nil }
        switch type {
        case "ready":
            return .ready
        case "answers":
            guard case .object(let answers)? = object["answers"] else { return nil }
            return .answers(answers)
        case "add-to-message":
            guard case .string(let text)? = object["text"],
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                text.utf16.count <= addToMessageMaxCharacters
            else { return nil }
            return .addToMessage(text)
        case "position":
            guard case .number(let y)? = object["y"], y >= 0 else { return nil }
            return .position(NSDecimalNumber(decimal: y).doubleValue)
        case "answers-text":
            guard case .string(let text)? = object["text"], text.utf16.count <= addToMessageMaxCharacters,
                case .number(let answered)? = object["answered"], case .number(let total)? = object["total"],
                let answeredCount = wholeNumber(answered), let totalCount = wholeNumber(total)
            else { return nil }
            return .answersText(ReportAnswersText(text: text, answered: answeredCount, total: totalCount))
        default:
            return nil
        }
    }

    private static func wholeNumber(_ value: Decimal) -> Int? {
        let number = NSDecimalNumber(decimal: value)
        let whole = number.intValue
        return value >= 0 && Decimal(whole) == value ? whole : nil
    }

    /// The `saved` message: whether everything the page reported is stored.
    public static func savedMessage(_ saved: Bool) -> String {
        #"{"protocol":"\#(name)","version":\#(version),"type":"saved","saved":\#(saved)}"#
    }

    /// The `init` message the host answers each `ready` with, as JSON: the answers to show, where
    /// Add to message goes (`session` is an explicit `null` for a report with none), that this
    /// host sends `saved`, the reading position to return to (an explicit `null` for none) and
    /// whether the host shows the session's message bar under the page.
    public static func initMessage(
        answers: [String: PaiJSONValue], session: (id: String, title: String?)?, position: Double? = nil,
        composer: Bool = false
    ) -> String {
        struct Session: Encodable {
            let id: String
            let title: String?

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(id, forKey: .id)
                try container.encode(title, forKey: .title)
            }
            enum CodingKeys: String, CodingKey { case id, title }
        }
        struct Message: Encodable {
            let protocolName: String
            let version: Int
            let type: String
            let answers: [String: PaiJSONValue]
            let session: Session?
            let position: Double?
            let composer: Bool

            enum CodingKeys: String, CodingKey {
                case protocolName = "protocol"
                case version, type, answers, session, acks, position, composer
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(protocolName, forKey: .protocolName)
                try container.encode(version, forKey: .version)
                try container.encode(type, forKey: .type)
                try container.encode(answers, forKey: .answers)
                try container.encode(session, forKey: .session)
                try container.encode(true, forKey: .acks)
                try container.encode(position, forKey: .position)
                try container.encode(composer, forKey: .composer)
            }
        }
        let message = Message(
            protocolName: name, version: version, type: "init", answers: answers,
            session: session.map { Session(id: $0.id, title: $0.title) }, position: position, composer: composer)
        let data = (try? JSONEncoder().encode(message)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The composer text after adding `text`: the draft kept, a blank line between, and nothing
    /// added twice. Text the same report added before (`replacing`) is replaced where it stands
    /// while the draft still holds it word for word.
    public static func appendToDraft(_ draft: String, _ text: String, replacing earlier: String? = nil) -> String {
        let added = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.contains(added) { return draft }
        if let earlier = earlier?.trimmingCharacters(in: .whitespacesAndNewlines), !earlier.isEmpty,
            let range = draft.range(of: earlier)
        {
            return draft.replacingCharacters(in: range, with: added)
        }

        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return added }
        var kept = Substring(draft)
        while let last = kept.last, last.isWhitespace { kept = kept.dropLast() }
        return "\(kept)\n\n\(added)"
    }

    /// The message sent from the bar under a report: what was typed, a blank line, the answers'
    /// text; either alone when the other is empty.
    public static func messageBody(typed: String, answers: String) -> String {
        [typed, answers].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
