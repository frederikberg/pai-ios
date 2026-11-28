import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts`'s `DynamicReport` (`wire.DynamicReportWire`): one
/// HTML page an agent published for the reader. `pai-cloud` owns this contract
/// (`docs/architecture/dynamic-reports.md`); this file mirrors it.
public struct DynamicReport: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// The session the report was published from; `nil` for a report published without one, and
    /// once that session's row is purged.
    public let sessionId: String?
    public let sessionTitle: String?
    /// The PAI link that opens the report in the app.
    public let url: String
    /// What the reader answered in the page: an object the page defines, stored whole.
    public let answers: [String: PaiJSONValue]
    public let createdAt: String
    public let updatedAt: String
    /// How many of the report's decisions the reader has answered; `nil` from a server that does
    /// not count them.
    public let decisions: ReportDecisionCount?

    enum CodingKeys: String, CodingKey {
        case id, title, url, answers, decisions
        case sessionId = "session_id"
        case sessionTitle = "session_title"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String, title: String, sessionId: String?, sessionTitle: String?, url: String,
        answers: [String: PaiJSONValue], createdAt: String, updatedAt: String,
        decisions: ReportDecisionCount? = nil
    ) {
        self.id = id
        self.title = title
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.url = url
        self.answers = answers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.decisions = decisions
    }
}

/// How many decisions a report asks for and how many of them are answered.
public struct ReportDecisionCount: Codable, Sendable, Equatable {
    public let answered: Int
    public let total: Int

    public init(answered: Int, total: Int) {
        self.answered = answered
        self.total = total
    }

    /// What the list says under a report, or `nil` for a report that asks for nothing.
    public var label: String? {
        total > 0 ? "\(answered) of \(total) answered" : nil
    }

    /// Whether a decision still waits for the reader.
    public var hasOpen: Bool { answered < total }
}

/// `GET /api/dynamic-reports` — newest first.
public struct DynamicReportsResponse: Codable, Sendable, Equatable {
    public let reports: [DynamicReport]

    public init(reports: [DynamicReport]) {
        self.reports = reports
    }
}

/// `GET`/`PUT` of one report: `{report}`.
public struct DynamicReportResponse: Codable, Sendable, Equatable {
    public let report: DynamicReport

    public init(report: DynamicReport) {
        self.report = report
    }
}
