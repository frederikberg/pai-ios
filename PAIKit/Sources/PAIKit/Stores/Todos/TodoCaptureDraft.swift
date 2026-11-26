import Foundation
import Observation

/// The add sheet's line and what the server's parser read in it, asked while typing (the web's
/// `useParse`): an older answer never lands after a newer one, and the add uses an answer only
/// when it was made for exactly the text being added. Without an answer the words are read when
/// the change goes out, so adding never waits for the parser.
@Observable
@MainActor
public final class TodoCaptureDraft {
    public var text = ""
    /// The last answer, possibly for slightly older text while the next one is on its way.
    public private(set) var answer: TodosParseAnswer?
    /// The text `answer` was made for: token offsets apply to exactly this text.
    public private(set) var answerText = ""

    /// How long typing pauses before the line goes to the parser.
    public static let debounceSeconds: TimeInterval = 0.12

    @ObservationIgnored private var asked = 0
    @ObservationIgnored private let parse: @Sendable (String) async throws -> TodosParseAnswer

    public init(parse: @escaping @Sendable (String) async throws -> TodosParseAnswer) {
        self.parse = parse
    }

    /// Ask the parser about the current text. A failed call changes nothing: the parser never
    /// refuses readable text, so a failure is the network, and the add goes without a preview.
    public func read() async {
        let current = text
        asked += 1
        let ticket = asked
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            answer = nil
            answerText = current
            return
        }
        guard let read = try? await parse(current), ticket == asked else { return }
        answer = read
        answerText = current
    }

    /// The parser's answer for exactly `text`, or nil.
    public func answer(for text: String) -> TodosParseAnswer? {
        answerText == text ? answer : nil
    }

    /// What the parser read, as chips in the order the words were typed.
    public var chips: [String] { answer?.tokens.map(\.display) ?? [] }

    /// What was read but cannot be used, such as a list the person has none of, with the
    /// parser's suggestion.
    public var issues: [String] {
        (answer?.issues ?? []).map { issue in
            issue.suggestion.map { "\(issue.message) Did you mean \($0)?" } ?? issue.message
        }
    }

    public var canAdd: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
