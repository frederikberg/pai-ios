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

/// Which answers a message from this device already carried, per report.
public protocol ReportSentAnswers: Sendable {
    func wasSent(_ text: String, reportID: String) -> Bool
    func remember(_ text: String, reportID: String)
}

/// Kept in the app's defaults as a digest of the text per report.
public struct DeviceReportSentAnswers: ReportSentAnswers {
    static let key = "reportAnswersSent"

    public init() {}

    private static func digest(_ text: String) -> String { TodoBlobs.sha256Hex(Data(text.utf8)) }

    public func wasSent(_ text: String, reportID: String) -> Bool {
        UserDefaults.standard.dictionary(forKey: Self.key)?[reportID] as? String == Self.digest(text)
    }

    public func remember(_ text: String, reportID: String) {
        var all = UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
        all[reportID] = Self.digest(text)
        UserDefaults.standard.set(all, forKey: Self.key)
    }
}

/// Where the reader was in each report, for as long as the app stays loaded.
@MainActor
public final class ReportPositions {
    public static let shared = ReportPositions()
    var y: [String: Double] = [:]

    public init() {}
}

/// One report on screen: its page, the answers the page reports, the message bar of its session
/// (the answers go with the message sent there), Add to message for a page built before the bar,
/// and the way back to the session. The host side of ``ReportProtocol``; Swift port of `ReportViewer.tsx`.
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
    /// Whether the report's session can be opened by this reader, so its message bar is shown
    /// under the page. Known before the page is.
    public private(set) var hasComposer = false
    /// What the page last said its answers are as message text.
    public private(set) var answersText: ReportAnswersText?
    /// Posts a message to the page outside a reply: `saved`. Set by whoever owns the web view.
    @ObservationIgnored public var deliver: (@MainActor (String) -> Void)?

    public let reportID: String

    private let api: DynamicReportsApiClient
    private let drafts: ReportComposerDrafts
    private let scheduler: DraftScheduler
    private var answers: [String: PaiJSONValue] = [:]
    private var isDirty = false
    private var saveTimer: Task<Void, Never>?
    private let sessionLoads: @MainActor (String) async -> Bool
    private let sentAnswers: any ReportSentAnswers
    /// The answers text the reader left out of this message; changed answers are offered again.
    private var leftOut: String?
    /// The answers text a message sent from this screen carried.
    private var carried: String?
    /// The text this report last added to the draft, replaced where it stands by the next.
    private var lastAdded: String?
    private let positions: ReportPositions

    /// - Parameter sessionLoads: whether the session with this id can be opened by this reader.
    public init(
        reportID: String, api: DynamicReportsApiClient, drafts: ReportComposerDrafts,
        scheduler: DraftScheduler = RealDraftScheduler(),
        sentAnswers: any ReportSentAnswers = DeviceReportSentAnswers(), positions: ReportPositions? = nil,
        sessionLoads: @escaping @MainActor (String) async -> Bool = { _ in false }
    ) {
        self.reportID = reportID
        self.api = api
        self.drafts = drafts
        self.scheduler = scheduler
        self.sentAnswers = sentAnswers
        self.positions = positions ?? .shared
        self.sessionLoads = sessionLoads
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
            // Before the page: its `init` says whether there is a message bar.
            if let sessionId = loadedReport.sessionId { hasComposer = await sessionLoads(sessionId) }
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
            // After the reply: the page learns that the answers `init` carried are not stored yet.
            if isUnsaved { Task { [weak self] in self?.deliver?(ReportProtocol.savedMessage(false)) } }
            return ReportProtocol.initMessage(
                answers: answers, session: session, position: positions.y[reportID], composer: hasComposer)
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
        case .position(let y):
            positions.y[reportID] = y
            return nil
        case .answersText(let reported):
            answersText = reported
            return nil
        }
    }

    /// The answers the next message from the bar carries, or nil when there are none to offer:
    /// nothing answered, left out by the reader, already carried by a message, or already in the
    /// draft.
    public var rider: ReportAnswersText? {
        guard hasComposer, let offered = answersText, offered.answered > 0 else { return nil }
        let text = offered.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != leftOut, text != carried, !sentAnswers.wasSent(text, reportID: reportID) else {
            return nil
        }
        if let sessionId = report?.sessionId, drafts.draftText(for: sessionId).contains(text) { return nil }
        return ReportAnswersText(text: text, answered: offered.answered, total: offered.total)
    }

    /// What the chip above the field says.
    public static func riderLabel(_ rider: ReportAnswersText) -> String {
        "Your answers go with this message (\(rider.answered) of \(rider.total) decision\(rider.total == 1 ? "" : "s"))"
    }

    /// The reader leaves the answers out of this message.
    public func leaveAnswersOut() {
        leftOut = answersText?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A message from the bar carried `text`: it is not offered again, on this device.
    public func answersWereSent(_ text: String) {
        carried = text
        sentAnswers.remember(text, reportID: reportID)
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
            key: sessionId,
            text: ReportProtocol.appendToDraft(drafts.draftText(for: sessionId), text, replacing: lastAdded))
        lastAdded = text
        drafts.requestComposerFocus()
        notice =
            hasComposer
            ? Notice(text: "Your answers are in the message box below, not sent yet.", sessionId: nil)
            : Notice(
                text:
                    "Your answers are in the message box, not sent yet. Go back to the session to read and send them.",
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
            if !isDirty {
                isUnsaved = false
                deliver?(ReportProtocol.savedMessage(true))
            }
        } catch {
            isDirty = true
            isUnsaved = true
            deliver?(ReportProtocol.savedMessage(false))
            if saveTimer == nil { scheduleSave(after: Self.saveRetrySeconds) }
        }
    }
}
