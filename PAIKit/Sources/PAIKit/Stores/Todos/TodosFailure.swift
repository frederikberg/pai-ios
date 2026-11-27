import Foundation

/// What a failed Todos request means for the change it carried, the web outbox's rules by name:
/// `isRetryable` there is `.retry` here, its `AuthExpiredError` is `.signedOut`, and every other
/// answer is a verdict on the change.
public enum TodosFailure: Equatable, Sendable {
    /// No answer, or one after which the same change, replayed under its own id, may still
    /// succeed: it stays queued.
    case retry
    /// The sign-in is gone: the whole queue stays, and goes out once there is one again.
    case signedOut
    /// The server refused the change. Sending it again gets the same answer.
    case refused(TodosRefusal)
    /// The server failed (500): sent again a bounded number of times, then refused.
    case serverError(TodosRefusal)

    /// Statuses after which a replay may still succeed. A conflict, a missing role and an unbuilt
    /// route do not improve by waiting.
    public static let retryableStatuses: Set<Int> = [408, 429, 502, 503, 504]

    public static func of(_ error: Error) -> TodosFailure {
        switch error {
        case let error as TodosApiError:
            if retryableStatuses.contains(error.statusCode) { return .retry }
            if error.statusCode == 500 { return .serverError(TodosRefusal(body: error.body)) }
            return .refused(TodosRefusal(body: error.body))
        case is TodosUnexpectedAnswer:
            return .signedOut
        case let error as TodosUnreadableAnswer:
            return .refused(TodosRefusal(code: nil, message: error.detail))
        case let error as PaiError:
            if error.isAuthenticationFailure { return .signedOut }
            switch error {
            case .transport: return .retry
            case .detail(_, let statusCode), .http(let statusCode, _):
                if retryableStatuses.contains(statusCode) { return .retry }
                let refusal = TodosRefusal(code: nil, message: error.userMessage)
                return statusCode == 500 ? .serverError(refusal) : .refused(refusal)
            case .decoding: return .refused(TodosRefusal(code: nil, message: error.userMessage))
            }
        default:
            // URLError and cancellation: the request never got an answer.
            return .retry
        }
    }
}

/// Why the server refused a change, in words a person reads.
public struct TodosRefusal: Equatable, Sendable {
    public let code: String?
    public let message: String

    public init(code: String?, message: String) {
        self.code = code
        self.message = message
    }

    /// The web outbox's `describeRefusal` with `plainRefusal` folded in: a conflict names who
    /// changed what first, the codes a person meets name what happened, anything else is the
    /// server's sentence without its `op 0 (todo.create):` prefix.
    init(body: TodosErrorBody) {
        code = body.error
        switch body.error {
        case "conflict" where !(body.since ?? []).isEmpty:
            // `since` runs oldest to newest: the one to name is the latest author.
            let last = body.since!.last!
            let what = last.changed.isEmpty ? "it" : last.changed.joined(separator: ", ")
            message = "\(last.actorLabel) changed \(what) first, so your change was not applied."
        case "undo_conflict" where body.fields != nil:
            let count = body.fields!.count
            message = "Can't undo: \(count) field\(count == 1 ? " was" : "s were") changed since."
        case "role":
            message = "You are not allowed to do that in this list."
        case "locked":
            message = "This list is locked and read-only, so it cannot be changed."
        case "not_found":
            message = "That todo does not exist, or is not shared with you."
        case "gone":
            message = "That todo was deleted."
        default:
            message = Self.withoutOpPrefix(body.message)
        }
    }

    static func withoutOpPrefix(_ message: String) -> String {
        guard message.hasPrefix("op "), let colon = message.range(of: "): ") ?? message.range(of: ": ") else {
            return message
        }
        let prefix = message[..<colon.lowerBound]
        guard prefix.dropFirst(3).first?.isNumber == true else { return message }
        return String(message[colon.upperBound...])
    }
}

extension TodosRefusal {
    /// The refusal told with the words it cost, so they can be typed again: "Not added “Oat
    /// milk”: This list is locked …". Without words (a tick, a desk move), the reason alone.
    public func told(about words: String?) -> String {
        guard let words, !words.isEmpty else { return message }
        return "Not added \u{201C}\(words)\u{201D}: \(message)"
    }
}
