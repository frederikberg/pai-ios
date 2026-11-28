import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Which door a change came through: the server records it on the change as its `source`.
public enum TodosSource: String, Codable, Sendable {
    /// The app's own screens.
    case ios
    /// An App Intent: Siri, Shortcuts, the Action button.
    case shortcut
    /// The share extension.
    case share
}

/// The server refused a Todos request and said why in its `{error, message, ...}` body.
public struct TodosApiError: Error, Equatable, Sendable {
    public let statusCode: Int
    public let body: TodosErrorBody

    public init(statusCode: Int, body: TodosErrorBody) {
        self.statusCode = statusCode
        self.body = body
    }

    public var code: String { body.error }
}

/// A success status whose body is not the JSON a Todos route answers: a sign-in page reached
/// through a redirect is the one way that happens, so the sign-in is what failed.
public struct TodosUnexpectedAnswer: Error, Equatable, Sendable {
    public let contentType: String?
}

/// A success whose JSON this build cannot read. For a write it still means the server applied it.
public struct TodosUnreadableAnswer: Error, Equatable, Sendable {
    public let detail: String
}

/// What the Todos engine needs from the backend. The store talks to this, never to a request.
public protocol TodosBackend: Sendable {
    func todosMe() async throws -> TodosMeAnswer
    func todosToday() async throws -> TodosTodayAnswer
    func todosQuery(_ request: TodosQueryRequest) async throws -> TodosQueryAnswer
    func todosApply(_ change: TodosChangeRequest, source: TodosSource) async throws -> TodosApplyResult
    func todosParse(text: String, list: String?, source: TodosSource) async throws -> TodosParseAnswer
    func todosEvents(after: Int) async throws -> TodosEventsAnswer
    func todosRunView(id: String, cursor: String?) async throws -> TodosQueryAnswer
    func todosViewCounts() async throws -> TodosViewCountsAnswer
    func todosDetail(ref: String) async throws -> TodosDetailAnswer
    /// The todo for its sheet: closed children too, and its last changes.
    func todosSheet(ref: String) async throws -> TodosDetailAnswer
    func todosUpcoming(days: Int) async throws -> TodosUpcomingAnswer
    func todosLogbook(cursor: String?) async throws -> TodosLogbookAnswer
    func todosSearch(_ request: TodosSearchRequest) async throws -> TodosSearchAnswer
    /// Records that something was opened from search (`POST /recents`).
    func todosRecent(kind: TodosRecent.Kind, target: String) async throws
    /// Plain words read into todos by a model; nothing is written.
    func todosCompose(_ request: TodosComposeRequest) async throws -> TodosComposeAnswer
    /// Undoes an applied change as a new change of its own (`request.changeId`).
    func todosUndo(changeId: String, _ request: TodosUndoRequest) async throws -> TodosApplyResult
    /// The people the caller may share a list with.
    func todosPeople() async throws -> TodosPeopleAnswer
    /// Stores a file's bytes under their hash (`PUT /blobs/<sha256>`), which an `attachment.add`
    /// then names. Sending bytes the server already holds changes nothing.
    func todosPutBlob(sha256: String, data: Data, contentType: String) async throws
    /// An attachment's bytes.
    func todosAttachment(id: String) async throws -> Data
}

extension PaiApiClient: TodosBackend {
    /// Every Todos route sits under this prefix, which guests reach too.
    static let todosPrefix = "/api/todos"

    public func todosMe() async throws -> TodosMeAnswer {
        try await todosSend("GET", "/me")
    }

    public func todosToday() async throws -> TodosTodayAnswer {
        try await todosSend("GET", "/today")
    }

    public func todosQuery(_ request: TodosQueryRequest) async throws -> TodosQueryAnswer {
        try await todosSend("POST", "/query", body: Self.jsonBody(request))
    }

    public func todosApply(_ change: TodosChangeRequest, source: TodosSource) async throws -> TodosApplyResult {
        try await todosSend("POST", "/apply", body: Self.jsonBody(change), source: source)
    }

    public func todosParse(text: String, list: String?, source: TodosSource) async throws -> TodosParseAnswer {
        struct Body: Encodable {
            let text: String
            let list: String?
        }
        return try await todosSend("POST", "/parse", body: Self.jsonBody(Body(text: text, list: list)), source: source)
    }

    /// The feed after `after`, answered at once (`wait=0`).
    public func todosEvents(after: Int) async throws -> TodosEventsAnswer {
        try await todosSend(
            "GET", "/events",
            query: [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "wait", value: "0")])
    }

    public func todosRunView(id: String, cursor: String?) async throws -> TodosQueryAnswer {
        try await todosSend(
            "GET", "/views/\(Self.escapedSegment(id))/run",
            query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }

    public func todosViewCounts() async throws -> TodosViewCountsAnswer {
        try await todosSend("GET", "/views/counts")
    }

    /// The todo with its open children, body left out.
    public func todosDetail(ref: String) async throws -> TodosDetailAnswer {
        try await todosSend(
            "GET", "/todos/\(Self.escapedSegment(ref))",
            query: [URLQueryItem(name: "children", value: "1"), URLQueryItem(name: "body", value: "0")])
    }

    public func todosSheet(ref: String) async throws -> TodosDetailAnswer {
        try await todosSend(
            "GET", "/todos/\(Self.escapedSegment(ref))",
            query: [
                URLQueryItem(name: "children", value: "1"), URLQueryItem(name: "closed", value: "1"),
                URLQueryItem(name: "history", value: "30"),
            ])
    }

    public func todosUpcoming(days: Int) async throws -> TodosUpcomingAnswer {
        try await todosSend("GET", "/upcoming", query: [URLQueryItem(name: "days", value: String(days))])
    }

    public func todosLogbook(cursor: String?) async throws -> TodosLogbookAnswer {
        try await todosSend("GET", "/logbook", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }

    public func todosSearch(_ request: TodosSearchRequest) async throws -> TodosSearchAnswer {
        try await todosSend("POST", "/search", body: Self.jsonBody(request))
    }

    public func todosRecent(kind: TodosRecent.Kind, target: String) async throws {
        _ = try await todosRaw(
            "POST", "/recents", body: Self.jsonBody(["kind": kind.rawValue, "target": target]),
            contentType: "application/json")
    }

    public func todosCompose(_ request: TodosComposeRequest) async throws -> TodosComposeAnswer {
        try await todosSend("POST", "/compose", body: Self.jsonBody(request))
    }

    public func todosUndo(changeId: String, _ request: TodosUndoRequest) async throws -> TodosApplyResult {
        try await todosSend(
            "POST", "/changes/\(Self.escapedSegment(changeId))/undo", body: Self.jsonBody(request))
    }

    public func todosPeople() async throws -> TodosPeopleAnswer {
        try await todosSend("GET", "/people")
    }

    public func todosPutBlob(sha256: String, data: Data, contentType: String) async throws {
        _ = try await todosRaw("PUT", "/blobs/\(Self.escapedSegment(sha256))", body: data, contentType: contentType)
    }

    public func todosAttachment(id: String) async throws -> Data {
        try await todosRaw("GET", "/attachments/\(Self.escapedSegment(id))", body: nil, contentType: nil)
    }

    /// A Todos route whose body, sent or answered, is a file's bytes; refusals are read as on
    /// every other Todos route.
    private func todosRaw(_ method: String, _ path: String, body: Data?, contentType: String?) async throws -> Data {
        var headers = ["X-Todos-Source": TodosSource.ios.rawValue]
        if let contentType { headers["Content-Type"] = contentType }
        let (data, _) = try await sendReadingRefusals(
            path: Self.todosPrefix + path, method: method, body: body, headers: headers
        ) { statusCode, data in
            (try? JSONDecoder().decode(TodosErrorBody.self, from: data)).map {
                TodosApiError(statusCode: statusCode, body: $0)
            }
        }
        return data
    }

    private static func escapedSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~:")))
            ?? value
    }

    private func todosSend<T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, source: TodosSource = .ios
    ) async throws -> T {
        // `X-Todos-Actor-Label` stays unset: the server derives a person's label and refuses the
        // header on a person's request.
        let (data, response) = try await sendReadingRefusals(
            path: Self.todosPrefix + path, method: method, query: query, body: body,
            headers: ["X-Todos-Source": source.rawValue]
        ) { statusCode, data in
            (try? JSONDecoder().decode(TodosErrorBody.self, from: data)).map {
                TodosApiError(statusCode: statusCode, body: $0)
            }
        }
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        guard contentType?.lowercased().contains("json") == true else {
            throw TodosUnexpectedAnswer(contentType: contentType)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TodosUnreadableAnswer(detail: "\(error)")
        }
    }
}
