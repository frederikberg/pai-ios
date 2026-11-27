import Foundation

extension PaiApiClient {

    // MARK: Dynamic reports

    /// The caller's reports, newest first. `before` is the oldest `created_at` of the previous page.
    public func listDynamicReports(before: String? = nil) async throws -> [DynamicReport] {
        var query: [URLQueryItem] = []
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        let response: DynamicReportsResponse = try await send(path: "/api/dynamic-reports", query: query)
        return response.reports
    }

    public func getDynamicReport(id: String) async throws -> DynamicReport {
        let response: DynamicReportResponse = try await send(path: "/api/dynamic-reports/\(id)")
        return response.report
    }

    /// The report's HTML. The route needs the bearer header, which is why the page is fetched here
    /// and handed to the web view as a string rather than loaded by URL: the page's own scripts
    /// never see the token.
    public func getDynamicReportPage(id: String) async throws -> String {
        let (_, body) = try await sendPassingThrough(
            path: "/api/dynamic-reports/\(id)/page", method: "GET", contentType: nil, passthrough: []
        )
        guard let html = String(data: body, encoding: .utf8) else {
            throw PaiError.transport("The report page was not text")
        }
        return html
    }

    /// Replaces the stored answers with the page's whole answers object.
    @discardableResult
    public func putDynamicReportAnswers(id: String, answers: [String: PaiJSONValue]) async throws -> DynamicReport {
        struct Body: Encodable { let answers: [String: PaiJSONValue] }
        let response: DynamicReportResponse = try await send(
            path: "/api/dynamic-reports/\(id)/answers", method: "PUT",
            body: try Self.jsonBody(Body(answers: answers)))
        return response.report
    }

    public func deleteDynamicReport(id: String) async throws {
        try await sendDiscardingResponse(path: "/api/dynamic-reports/\(id)", method: "DELETE", contentType: nil)
    }
}
