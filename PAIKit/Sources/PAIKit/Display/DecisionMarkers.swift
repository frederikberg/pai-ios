import Foundation

/// A decision embedded in an assistant reply: a line that is exactly `{{D<n>}}` (up to three
/// spaces of indent, as markdown allows before a paragraph, and trailing spaces or tabs) stands
/// for the session's decision `n` and is drawn as its card. Inside a fenced code block it is code
/// and stays text, so a reply can show the marker itself. Swift port of the web's
/// `utils/decisionMarkers.ts`; the contract is pai-cloud's `docs/architecture/notifications.md` →
/// Decisions.
public enum DecisionMarkers {

    /// One piece of a reply cut at its markers.
    public enum Segment: Equatable, Sendable {
        case markdown(String)
        case decision(Int)
    }

    /// The reply cut at its decision markers: the markdown between them, and the numbers they
    /// name, in order. A chunk that is only whitespace is dropped; text without a marker is one
    /// segment.
    public static func split(_ text: String) -> [Segment] {
        guard text.contains("{{D") else { return [.markdown(text)] }
        var segments: [Segment] = []
        var chunk: [Substring] = []
        var fence: (character: Character, length: Int)?

        func flush() {
            let joined = chunk.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(joined))
            }
            chunk = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                if MarkdownFence.closes(line, character: open.character, length: open.length) { fence = nil }
                chunk.append(line)
                continue
            }
            if let opened = MarkdownFence.opening(line) {
                fence = opened
                chunk.append(line)
                continue
            }
            if let number = markerNumber(line) {
                flush()
                segments.append(.decision(number))
                continue
            }
            chunk.append(line)
        }
        flush()
        return segments
    }

    /// The decision numbers `text` embeds, in order.
    public static func embeddedNumbers(in text: String) -> [Int] {
        guard text.contains("{{D") else { return [] }
        return split(text).compactMap { if case .decision(let number) = $0 { number } else { nil } }
    }

    /// The decision numbers one message embeds: only an assistant reply's own text can.
    public static func embeddedNumbers(of message: Message) -> [Int] {
        guard message.type == .assistant, let content = message.content else { return [] }
        return embeddedNumbers(in: content)
    }

    // MARK: - Line grammar

    /// The number of a line that is exactly `{{D<n>}}`, trailing spaces or tabs allowed.
    private static func markerNumber(_ line: Substring) -> Int? {
        guard var rest = MarkdownFence.dropIndent(line), rest.hasPrefix("{{D") else { return nil }
        rest = rest.dropFirst(3)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.hasPrefix("}}") else { return nil }
        rest = rest.dropFirst(2)
        return rest.allSatisfy { $0 == " " || $0 == "\t" } ? number : nil
    }
}
