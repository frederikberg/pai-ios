import Foundation
import Observation

public protocol DynamicReportsApiClient: Sendable {
    func listDynamicReports(before: String?) async throws -> [DynamicReport]
    func getDynamicReport(id: String) async throws -> DynamicReport
    func getDynamicReportPage(id: String) async throws -> String
    func putDynamicReportAnswers(id: String, answers: [String: PaiJSONValue]) async throws -> DynamicReport
    func deleteDynamicReport(id: String) async throws
}

extension PaiApiClient: DynamicReportsApiClient {}

/// The Reports app's list: the caller's reports, newest first, paged by the oldest `created_at`
/// held. Swift port of `ReportList.tsx`.
@MainActor
@Observable
public final class ReportListStore {
    /// The server's default page; a shorter answer is the last page.
    public nonisolated static let pageSize = 100

    public private(set) var reports: [DynamicReport] = []
    public private(set) var isLoading = true
    public private(set) var hasMore = false
    public private(set) var errorMessage: String?

    private let api: DynamicReportsApiClient

    public init(api: DynamicReportsApiClient) {
        self.api = api
    }

    /// Reads the newest page again, replacing what is held.
    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let rows = try await api.listDynamicReports(before: nil)
            reports = rows
            hasMore = rows.count >= Self.pageSize
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "The reports could not be loaded."
        }
    }

    /// The next, older page.
    public func loadMore() async {
        guard hasMore, let last = reports.last else { return }
        do {
            let rows = try await api.listDynamicReports(before: last.createdAt)
            let known = Set(reports.map(\.id))
            reports += rows.filter { !known.contains($0.id) }
            hasMore = rows.count >= Self.pageSize
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "The reports could not be loaded."
        }
    }

    /// A report deleted from its own screen leaves the list without another request.
    public func remove(id: String) {
        reports.removeAll { $0.id == id }
    }
}
