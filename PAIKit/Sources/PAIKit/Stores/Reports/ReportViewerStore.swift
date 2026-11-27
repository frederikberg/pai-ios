import Foundation
import Observation

/// The composer drafts a report writes into: `DraftStore` in the app, a fake in a test.
@MainActor
public protocol ReportComposerDrafts: AnyObject {
    func draftText(for key: String) -> String
    func setDraftText(key: String, text: String)
    func requestComposerFocus()
}

extension DraftStore: ReportComposerDrafts {
    public func draftText(for key: String) -> String { draft(for: key).text }
}

/// One report on screen: its page, the answers the page reports, Add to message and the way back
/// to the session. The host side of ``ReportProtocol``; Swift port of `ReportViewer.tsx`.
///
/// The view owns the web view and feeds this store every message the page posts as JSON
/// (``receive(json:)``); what the store answers (the `init` message) it hands back for the view
/// to deliver, so nothing here needs WebKit.
@MainActor
@Observable
public final class ReportViewerStore {
    /// A line at the foot of the screen. `sessionId` is the session to offer a way back to, when
    /// the notice is about its composer.
    public struct Notice: Equatable, Sendable {
        public let text: String
        public let sessionId: String?
    }

    /// How long answers rest before they are written; leaving writes them at once.
    public static let saveDebounceSeconds: TimeInterval = 0.6
    public static let saveRetrySeconds: TimeInterval = 3

    public private(set) var report: DynamicReport?
    /// The page's HTML once fetched.
    public private(set) var pageHTML: String?
    public private(set) var errorMessage: String?
    public private(set) var notice: Notice?
    /// Whether the page reported answers that are not stored yet.
    public private(set) var isUnsaved = false
    public private(set) var isDeleted = false

    public let reportID: String

    private let api: DynamicReportsApiClient
    private let drafts: ReportComposerDrafts
    private let scheduler: DraftScheduler
    private var answers: [String: PaiJSONValue] = [:]
    private var isDirty = false
    private var saveTimer: Task<Void, Never>?

    public init(
        reportID: String, api: DynamicReportsApiClient, drafts: ReportComposerDrafts,
        scheduler: DraftScheduler = RealDraftScheduler()
    ) {
        self.reportID = reportID
        self.api = api
        self.drafts = drafts
        self.scheduler = scheduler
    }

    /// Fetches the report and its page. The page is fetched by the app, with the token, so the
    /// web view that shows it never holds one.
    public func load() async {
        errorMessage = nil
        do {
            async let row = api.getDynamicReport(id: reportID)
            async let html = api.getDynamicReportPage(id: reportID)
            let (loadedReport, loadedPage) = try await (row, html)
            answers = loadedReport.answers
            report = loadedReport
            pageHTML = loadedPage
        } catch let error as PaiError {
            errorMessage = error.isNotFound ? "This report does not exist, or is not yours." : error.userMessage
        } catch {
            errorMessage = "The report could not be loaded."
        }
    }

    /// What the page posted, as JSON. Returns the JSON of the message to deliver to the page, if
    /// any: the `init` that answers `ready`.
    @discardableResult
    public func receive(json: String) -> String? {
        guard let message = ReportProtocol.parse(json: json) else { return nil }
        switch message {
        case .ready:
            let session = report?.sessionId.map { (id: $0, title: report?.sessionTitle) }
            return ReportProtocol.initMessage(answers: answers, session: session)
        case .answers(let reported):
            answers = reported
            isDirty = true
            isUnsaved = true
            scheduleSave(after: Self.saveDebounceSeconds)
            return nil
        case .addToMessage(let text):
            Task { await save() }
            addToMessage(text)
            return nil
        }
    }

    /// Puts `text` into the report session's composer draft, unsent, and says so. A report with no
    /// session has no message to add to.
    func addToMessage(_ text: String) {
        guard let sessionId = report?.sessionId else {
            notice = Notice(
                text: "This report is not tied to a session, so there is no message to add to.", sessionId: nil)
            return
        }
        drafts.setDraftText(
            key: sessionId, text: ReportProtocol.appendToDraft(drafts.draftText(for: sessionId), text))
        drafts.requestComposerFocus()
        notice = Notice(
            text: "Your answers are in the message box, not sent yet. Go back to the session to read and send them.",
            sessionId: sessionId)
    }

    public func dismissNotice() {
        notice = nil
    }

    /// Writes answers that are still resting; what leaving the screen calls.
    public func leave() async {
        await save()
    }

    /// Deletes the report for good. Returns whether it is gone.
    public func delete() async -> Bool {
        do {
            isDirty = false
            saveTimer?.cancel()
            try await api.deleteDynamicReport(id: reportID)
            isDeleted = true
            return true
        } catch {
            notice = Notice(text: "The report could not be deleted.", sessionId: nil)
            return false
        }
    }

    private func scheduleSave(after seconds: TimeInterval) {
        saveTimer?.cancel()
        saveTimer = Task { [weak self, scheduler] in
            try? await scheduler.sleep(seconds: seconds)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Stores the latest answers. A failed write is repeated unless newer answers superseded it.
    private func save() async {
        saveTimer?.cancel()
        saveTimer = nil
        guard isDirty else { return }
        let sent = answers
        isDirty = false
        do {
            _ = try await api.putDynamicReportAnswers(id: reportID, answers: sent)
            if !isDirty { isUnsaved = false }
        } catch {
            isDirty = true
            isUnsaved = true
            if saveTimer == nil { scheduleSave(after: Self.saveRetrySeconds) }
        }
    }
}
