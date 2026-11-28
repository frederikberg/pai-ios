import Foundation
import Observation

/// The add sheet's line and what the server's parser read in it, asked while typing (the web's
/// `useParse`). The last answer stays while the next one is on its way, placed on the line as it
/// is now (`marks`), so a word once read stays marked through every keystroke; an older answer
/// never lands after a newer one, and the add uses an answer only when it was made for exactly
/// the text being added. Without an answer the words are read when the change goes out, so
/// adding never waits for the parser.
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
    /// The ask whose answer is held, or after which nothing older may land.
    @ObservationIgnored private var landed = 0
    @ObservationIgnored private let parse: @Sendable (String) async throws -> TodosParseAnswer

    /// `text` is a line already typed when the sheet opens.
    public init(text: String = "", parse: @escaping @Sendable (String) async throws -> TodosParseAnswer) {
        self.text = text
        self.parse = parse
    }

    /// Ask the parser about the current text. A failed call changes nothing: the parser never
    /// refuses readable text, so a failure is the network, and the add goes without a preview.
    public func read() async {
        let current = text
        asked += 1
        let ticket = asked
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            landed = ticket
            answer = nil
            answerText = current
            return
        }
        guard let read = try? await parse(current), ticket > landed else { return }
        landed = ticket
        answer = read
        answerText = current
    }

    /// The words the parser read as fields, where they sit in the line as it is now: the last
    /// answer's tokens carried over what was typed since.
    public var marks: [TodoParseToken] {
        guard let answer else { return [] }
        return TodoLineTokens.carry(from: answerText, to: text, tokens: answer.tokens).tokens
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

    /// The line to add and the parser's answer for exactly it, emptying the line, so a second tap
    /// on Add (or Return) before the sheet has left finds nothing to add.
    public func take() -> (text: String, answer: TodosParseAnswer?)? {
        guard canAdd else { return nil }
        let taken = (text, answer(for: text))
        text = ""
        answer = nil
        answerText = ""
        asked += 1
        landed = asked
        return taken
    }
}

/// The parser's tokens on a line typed on since they were read, the web's `carryTokens`
/// (`quickadd/chips.ts`).
public enum TodoLineTokens {
    /// The tokens of an answer read for `from`, placed on the line `to`. One edit separates the
    /// two lines (the longest common start and end): a token before it keeps its offsets, one
    /// after it moves by the edit's length, and one the edit touches or extends (typed straight
    /// against it) is left out, since the next answer decides what that word is. `complete` says
    /// every token survived, so the answer's fields still describe the line. Offsets are UTF-16
    /// code units.
    public static func carry(from: String, to: String, tokens: [TodoParseToken]) -> (
        tokens: [TodoParseToken], complete: Bool
    ) {
        if from == to { return (tokens, true) }
        let old = Array(from.utf16)
        let new = Array(to.utf16)
        let longest = min(old.count, new.count)
        var prefix = 0
        while prefix < longest, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < longest - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let editEnd = old.count - suffix
        let shift = new.count - old.count
        func isSpace(_ index: Int) -> Bool {
            guard new.indices.contains(index) else { return true }
            return Unicode.Scalar(new[index]).map { $0.properties.isWhitespace } ?? false
        }
        var kept: [TodoParseToken] = []
        for token in tokens {
            if token.end <= prefix, isSpace(token.end) {
                kept.append(token)
            } else if token.start >= editEnd, isSpace(token.start + shift - 1) {
                kept.append(
                    TodoParseToken(
                        start: token.start + shift, end: token.end + shift, kind: token.kind, value: token.value,
                        display: token.display))
            }
        }
        return (kept, kept.count == tokens.count)
    }
}
