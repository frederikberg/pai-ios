import Foundation

/// The body of `POST /api/me/self-reports`. The client's own `id` makes a retry idempotent: the
/// server answers the stored row for an id it already has.
public struct SelfReportCreateBody: Encodable, Sendable, Equatable {
    public let id: String
    public let text: String?
    public let feel: String?
    public let isPrivate: Bool
    public let at: String
    public let source: String

    public init(id: String, text: String?, feel: String?, isPrivate: Bool, at: String, source: String = "ios") {
        self.id = id
        self.text = text
        self.feel = feel
        self.isPrivate = isPrivate
        self.at = at
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, text, feel, at, source
        case isPrivate = "private"
    }
}

/// The body of `PATCH /api/me/self-reports/{id}`. A key left nil is absent and changes nothing;
/// ``clearText`` and ``clearFeel`` send an explicit `null`, which the server reads as "remove it".
public struct SelfReportPatchBody: Encodable, Sendable, Equatable {
    public var text: String?
    public var clearText = false
    public var feel: String?
    public var clearFeel = false
    public var isPrivate: Bool?
    public var at: String?

    public init(
        text: String? = nil, clearText: Bool = false, feel: String? = nil, clearFeel: Bool = false,
        isPrivate: Bool? = nil, at: String? = nil
    ) {
        self.text = text
        self.clearText = clearText
        self.feel = feel
        self.clearFeel = clearFeel
        self.isPrivate = isPrivate
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case text, feel, at
        case isPrivate = "private"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if clearText {
            try container.encodeNil(forKey: .text)
        } else if let text {
            try container.encode(text, forKey: .text)
        }
        if clearFeel {
            try container.encodeNil(forKey: .feel)
        } else if let feel {
            try container.encode(feel, forKey: .feel)
        }
        if let isPrivate { try container.encode(isPrivate, forKey: .isPrivate) }
        if let at { try container.encode(at, forKey: .at) }
    }
}

extension PaiApiClient {

    // MARK: Me — self-reports and overview

    /// Every read here is the owner's own, so it asks for private text: the server's default
    /// redacts it for every other reader.
    private static let includePrivate = URLQueryItem(name: "private", value: "include")

    /// `GET /api/me/overview`: `days` days ending at `end` (`yyyy-MM-dd`, nil = today).
    public func getMeOverview(days: Int, end: String?) async throws -> MeOverview {
        var query = [URLQueryItem(name: "days", value: String(days)), Self.includePrivate]
        if let end { query.append(URLQueryItem(name: "end", value: end)) }
        return try await send(path: "/api/me/overview", query: query)
    }

    /// `GET /api/me/day/{date}`: the day in full, entries and what it held with summaries.
    public func getMeDay(date: String) async throws -> MeDay {
        try await send(path: "/api/me/day/\(date)", query: [Self.includePrivate])
    }

    /// `GET /api/me/tasks`: one Berlin day of the Todoist list (`date` nil = today). `fresh` asks
    /// the server to read Todoist again when its last read is older than a few seconds.
    public func getMeTasks(date: String?, fresh: Bool) async throws -> MeTasks {
        var query: [URLQueryItem] = []
        if let date { query.append(URLQueryItem(name: "date", value: date)) }
        if fresh { query.append(URLQueryItem(name: "fresh", value: "1")) }
        return try await send(path: "/api/me/tasks", query: query)
    }

    /// `GET /api/me/self-reports`: one page, newest first; `before` is the previous page's `next_before`.
    public func getSelfReports(before: String?, limit: Int, feel: String?, privateOnly: Bool) async throws
        -> SelfReportPage
    {
        var query = [URLQueryItem(name: "limit", value: String(limit)), Self.includePrivate]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        if let feel { query.append(URLQueryItem(name: "feel", value: feel)) }
        if privateOnly { query.append(URLQueryItem(name: "private_only", value: "1")) }
        return try await send(path: "/api/me/self-reports", query: query)
    }

    /// `POST /api/me/self-reports`: 201 with the stored row; the same `id` again answers the row
    /// already stored.
    public func createSelfReport(_ body: SelfReportCreateBody) async throws -> SelfReport {
        try await send(path: "/api/me/self-reports", method: "POST", body: try Self.jsonBody(body))
    }

    public func patchSelfReport(id: String, _ body: SelfReportPatchBody) async throws -> SelfReport {
        try await send(path: "/api/me/self-reports/\(id)", method: "PATCH", body: try Self.jsonBody(body))
    }

    /// Soft delete; ``restoreSelfReport(id:)`` undoes it.
    public func deleteSelfReport(id: String) async throws {
        try await sendDiscardingResponse(path: "/api/me/self-reports/\(id)", method: "DELETE")
    }

    public func restoreSelfReport(id: String) async throws {
        try await sendDiscardingResponse(path: "/api/me/self-reports/\(id)/restore", method: "POST")
    }
}
