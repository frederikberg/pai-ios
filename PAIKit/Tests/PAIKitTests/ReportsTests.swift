import XCTest

@testable import PAIKit

/// The Reports app's package side: the wire shape, the host side of the page protocol, the
/// sandbox's decisions, the links that open a report, and the two stores.
final class ReportsTests: XCTestCase {

    private func message(_ type: String, _ fields: String = "") -> String {
        """
        {"protocol": "pai-report", "version": 1, "type": "\(type)"\(fields.isEmpty ? "" : ", " + fields)}
        """
    }

    // MARK: Wire

    func testTheFixtureReportsDecode() throws {
        let list = try JSONDecoder().decode(
            DynamicReportsResponse.self, from: PaiFixtures.data(PaiFixtures.dynamicReports))
        XCTAssertEqual(list.reports.count, 2)
        XCTAssertEqual(list.reports[0].answers["d1"], .string("Option B"))
        XCTAssertNil(list.reports[1].sessionId)
        XCTAssertEqual(list.reports[1].answers, [:])
        let one = try JSONDecoder().decode(
            DynamicReportResponse.self, from: PaiFixtures.data(PaiFixtures.dynamicReportDetail))
        XCTAssertEqual(one.report.id, PaiFixtures.reportFixtureID)
    }

    func testTheFixtureRoutesAnswerTheScreensRequests() {
        for (method, path) in [
            ("GET", "/api/dynamic-reports"), ("GET", "/api/dynamic-reports/anything"),
            ("GET", "/api/dynamic-reports/anything/page"), ("PUT", "/api/dynamic-reports/anything/answers"),
        ] {
            XCTAssertEqual(PaiFixtureURLProtocol.route(method: method, path: path).status, 200, path)
        }
        XCTAssertNotNil(Route.named("report", sessionID: "s"))
        XCTAssertEqual(Route.named("reports", sessionID: "s"), .reports)
    }

    // MARK: The page protocol

    func testAWellFormedMessageOfEachTypeParses() {
        XCTAssertEqual(ReportProtocol.parse(json: message("ready")), .ready)
        XCTAssertEqual(
            ReportProtocol.parse(json: message("answers", #""answers": {"d1": "B", "n": 3, "on": true}"#)),
            .answers(["d1": .string("B"), "n": .number(3), "on": .bool(true)]))
        XCTAssertEqual(
            ReportProtocol.parse(json: message("add-to-message", #""text": "Hello""#)), .addToMessage("Hello"))
    }

    func testAnythingNotOfThisProtocolIsNil() {
        XCTAssertNil(ReportProtocol.parse(json: "not json"))
        XCTAssertNil(ReportProtocol.parse(json: "[]"))
        XCTAssertNil(ReportProtocol.parse(json: #"{"type": "ready"}"#))
        XCTAssertNil(ReportProtocol.parse(json: #"{"protocol": "other", "version": 1, "type": "ready"}"#))
        XCTAssertNil(ReportProtocol.parse(json: #"{"protocol": "pai-report", "version": 2, "type": "ready"}"#))
        XCTAssertNil(ReportProtocol.parse(json: message("init")), "a host message is not a page message")
        XCTAssertNil(ReportProtocol.parse(json: message("answers", #""answers": [1]"#)))
        XCTAssertNil(ReportProtocol.parse(json: message("answers")))
    }

    func testAddToMessageNeedsTextWithinTheDraftsCeiling() {
        XCTAssertNil(ReportProtocol.parse(json: message("add-to-message", #""text": "  \n""#)))
        XCTAssertNil(ReportProtocol.parse(json: message("add-to-message", #""text": 5"#)))
        XCTAssertNil(ReportProtocol.parse(json: message("add-to-message")))
        let longest = String(repeating: "a", count: ReportProtocol.addToMessageMaxCharacters)
        XCTAssertNotNil(ReportProtocol.parse(json: message("add-to-message", #""text": "\#(longest)""#)))
        XCTAssertNil(ReportProtocol.parse(json: message("add-to-message", #""text": "\#(longest)a""#)))
    }

    func testTheInitMessageCarriesAnswersAndTheSessionOrAnExplicitNull() throws {
        func decode(_ json: String) throws -> [String: PaiJSONValue] {
            guard case .object(let object) = try JSONDecoder().decode(PaiJSONValue.self, from: Data(json.utf8))
            else { return [:] }
            return object
        }
        let with = try decode(
            ReportProtocol.initMessage(answers: ["d1": .string("B")], session: (id: "s1", title: "Plan")))
        XCTAssertEqual(with["protocol"], .string("pai-report"))
        XCTAssertEqual(with["version"], .number(1))
        XCTAssertEqual(with["type"], .string("init"))
        XCTAssertEqual(with["answers"], .object(["d1": .string("B")]))
        XCTAssertEqual(with["session"], .object(["id": .string("s1"), "title": .string("Plan")]))
        let without = try decode(ReportProtocol.initMessage(answers: [:], session: nil))
        XCTAssertEqual(without["session"], .null, "the page reads a missing session as null")
        let untitled = try decode(ReportProtocol.initMessage(answers: [:], session: (id: "s1", title: nil)))
        XCTAssertEqual(untitled["session"], .object(["id": .string("s1"), "title": .null]))
    }

    func testAddingToADraftKeepsItSeparatesWithABlankLineAndNeverAddsTwice() {
        XCTAssertEqual(ReportProtocol.appendToDraft("", "  A  "), "A")
        XCTAssertEqual(ReportProtocol.appendToDraft("  \n", "A"), "A")
        XCTAssertEqual(ReportProtocol.appendToDraft("Hello  \n", "A"), "Hello\n\nA")
        XCTAssertEqual(ReportProtocol.appendToDraft("Hello\n\nA", "A"), "Hello\n\nA")
    }

    // MARK: The sandbox

    func testTheContentRulesBlockTheNetworkExceptTheFontHosts() throws {
        let rules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(ReportSandbox.contentRules.utf8)) as? [[String: Any]])
        let actions = rules.compactMap { ($0["action"] as? [String: String])?["type"] }
        XCTAssertEqual(actions, ["block", "block", "ignore-previous-rules", "ignore-previous-rules"])
        let filters = rules.compactMap { ($0["trigger"] as? [String: String])?["url-filter"] }
        XCTAssertEqual(filters[0], "^https?://")
        XCTAssertEqual(filters[2], #"^https://fonts\.googleapis\.com/"#)
        XCTAssertEqual(filters[3], #"^https://fonts\.gstatic\.com/"#)
        XCTAssertFalse(filters.contains { $0.contains("|") }, "a url-filter has no alternation")
    }

    func testALinkLeavesThePageOnlyWhenTappedAndConfirmed() {
        let web = URL(string: "https://example.com/x")!
        XCTAssertEqual(ReportSandbox.decide(url: web, isTappedLink: true), .confirmOpening(web))
        XCTAssertEqual(ReportSandbox.decide(url: web, isTappedLink: false), .cancel, "a script's redirect")
        XCTAssertEqual(ReportSandbox.decide(url: URL(string: "about:blank#top"), isTappedLink: true), .allow)
        XCTAssertEqual(ReportSandbox.decide(url: nil, isTappedLink: false), .allow)
        for odd in ["javascript:alert(1)", "mailto:a@b.c", "tel:123", "file:///etc/passwd", "pai://session/x"] {
            XCTAssertEqual(ReportSandbox.decide(url: URL(string: odd), isTappedLink: true), .cancel, odd)
        }
    }

    func testTheBridgeForwardsOnlyThePagesMessagesOfThisProtocol() {
        XCTAssertTrue(ReportSandbox.bridgeScript.contains("messageHandlers.paiReport"))
        XCTAssertTrue(ReportSandbox.bridgeScript.contains("event.source !== window"))
        XCTAssertTrue(ReportSandbox.bridgeScript.contains("'pai-report'"))
        XCTAssertEqual(ReportSandbox.deliveryScript(messageJSON: "{}"), "window.postMessage({}, '*');")
    }

    // MARK: Links

    func testALinkOnTheBackendHostOpensTheReport() {
        func parse(_ string: String, host: String? = "pai.example.com") -> ReportLink? {
            ReportLink.parse(URL(string: string)!, backendHost: host)
        }
        let id = "5d3f7b20-0000-4a6e-9c1d-7e5a2b6f0d77"
        XCTAssertEqual(parse("https://pai.example.com/apps/reports/\(id)"), .report(id: id))
        XCTAssertEqual(parse("https://pai.example.com/apps/reports"), .list)
        XCTAssertNil(parse("https://evil.example.org/apps/reports/\(id)"))
        XCTAssertNil(parse("http://pai.example.com/apps/reports/\(id)"))
        XCTAssertNil(parse("https://pai.example.com/apps/reports/\(id)", host: nil))
        XCTAssertNil(parse("https://pai.example.com/apps/reports/a%2Fb"))
        XCTAssertNil(parse("https://pai.example.com/apps/reports/a/b"))
        XCTAssertNil(parse("https://pai.example.com/apps/notes/\(id)"))
    }

    func testAUniversalLinkAndTheCustomSchemeOpenTheSameScreens() {
        let id = "5d3f7b20-0000-4a6e-9c1d-7e5a2b6f0d77"
        XCTAssertEqual(
            DeepLink.from(webURL: URL(string: "https://pai.example.com/apps/reports/\(id)")!), .reports(id: id))
        XCTAssertEqual(DeepLink.from(webURL: URL(string: "https://pai.example.com/apps/reports")!), .reports(id: nil))
        XCTAssertNil(DeepLink.from(webURL: URL(string: "https://pai.example.com/apps/reports/-/x")!))
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://reports/\(id)")!), .reports(id: id))
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://reports")!), .reports(id: nil))
        XCTAssertEqual(DeepLink.reports(id: id).url, URL(string: "pai://reports/\(id)"))
        XCTAssertEqual(DeepLink.reports(id: id).routes, [.reports, .report(id: id)])
        XCTAssertEqual(DeepLink.reports(id: nil).routes, [.reports])
    }

    func testReportsAreOpenToGuestsAndPutAwayAtNight() {
        XCTAssertTrue(Capabilities(role: .guest).canOpenReports)
        XCTAssertTrue(Capabilities(role: .owner).canOpenReports)
        XCTAssertFalse(Capabilities.unknown.canOpenReports)
        let entry = AppRegistry.all.first { $0.id == "reports" }
        XCTAssertEqual(entry?.route, .reports)
        XCTAssertEqual(entry?.isNightBlocked, true)
    }

    func testAReportOpenedFromASessionLeavesTheSessionUnderneath() {
        let router = Router(gate: .ready)
        router.push(.session(id: "s1"))
        router.surface(.report(id: "r1"))
        XCTAssertEqual(router.path, [.session(id: "s1"), .report(id: "r1")])
        XCTAssertEqual(router.openSessionID, "s1")
        router.surface(.report(id: "r1"))
        XCTAssertEqual(router.path.count, 2, "a link tapped twice does not stack two")
    }

    // MARK: List store

    @MainActor
    func testTheListPagesOnTheOldestCreatedAtAndStopsOnAShortPage() async {
        let api = FakeReportsApi()
        let full = (0..<ReportListStore.pageSize).map {
            report("r\($0)", created: "2026-11-\(String(format: "%02d", 28 - $0 % 27))")
        }
        api.pages = [full, [report("old1", created: "2026-01-01"), report("r0", created: "2026-11-28")]]
        let store = ReportListStore(api: api)
        await store.load()
        XCTAssertTrue(store.hasMore)
        let oldest = store.reports[ReportListStore.pageSize - 1].createdAt
        await store.loadMore()
        XCTAssertEqual(store.reports.count, ReportListStore.pageSize + 1, "an id seen twice is kept once")
        XCTAssertEqual(store.reports.last?.id, "old1")
        XCTAssertFalse(store.hasMore)
        XCTAssertEqual(api.listCalls, [nil, oldest])
    }

    @MainActor
    func testAFailedListSaysSoAndKeepsWhatWasShown() async {
        let api = FakeReportsApi()
        api.pages = [[report("r1", created: "2026-11-01")]]
        let store = ReportListStore(api: api)
        await store.load()
        api.listError = PaiError.transport("offline")
        await store.load()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.reports.count, 1)
    }

    // MARK: Viewer store

    @MainActor
    private func viewer(
        report: DynamicReport? = nil, api: FakeReportsApi = FakeReportsApi(),
        drafts: FakeComposerDrafts = FakeComposerDrafts()
    ) async -> (ReportViewerStore, FakeReportsApi, FakeComposerDrafts) {
        api.detail = report ?? self.report("r1", created: "2026-11-01", session: "s1", answers: ["d1": .string("A")])
        let store = ReportViewerStore(reportID: "r1", api: api, drafts: drafts, scheduler: InstantScheduler())
        await store.load()
        return (store, api, drafts)
    }

    @MainActor
    func testLoadingFetchesTheReportAndItsPage() async {
        let (store, api, _) = await viewer()
        XCTAssertEqual(store.report?.id, "r1")
        XCTAssertEqual(store.pageHTML, "<html>page</html>")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(api.pageFetches, ["r1"])
    }

    @MainActor
    func testAMissingReportSaysItDoesNotExist() async {
        let api = FakeReportsApi()
        api.detailError = PaiError.http(statusCode: 404, reason: "Not Found")
        let store = ReportViewerStore(
            reportID: "gone", api: api, drafts: FakeComposerDrafts(), scheduler: InstantScheduler())
        await store.load()
        XCTAssertEqual(store.errorMessage, "This report does not exist, or is not yours.")
        XCTAssertNil(store.pageHTML)
    }

    @MainActor
    func testReadyIsAnsweredWithTheStoredAnswersAndTheSession() throws {
        let store = ReportViewerStore(
            reportID: "r1", api: FakeReportsApi(), drafts: FakeComposerDrafts(), scheduler: InstantScheduler())
        XCTAssertNotNil(store.receive(json: message("ready")), "even before the report loaded, init is answered")
    }

    @MainActor
    func testTheInitAnswersCarryWhatWasStored() async throws {
        let (store, _, _) = await viewer()
        let reply = try XCTUnwrap(store.receive(json: message("ready")))
        XCTAssertTrue(reply.contains(#""d1":"A""#))
        XCTAssertTrue(reply.contains(#""id":"s1""#))
        XCTAssertNil(store.receive(json: "garbage"))
    }

    @MainActor
    func testReportedAnswersAreStoredWholeAfterTheDebounce() async {
        let (store, api, _) = await viewer()
        _ = store.receive(json: message("answers", #""answers": {"d1": "B"}"#))
        XCTAssertTrue(store.isUnsaved)
        await waitUntil { !store.isUnsaved }
        XCTAssertEqual(api.putAnswers, [["d1": .string("B")]])
    }

    @MainActor
    func testAFailedWriteIsRepeatedUntilItLands() async {
        let (store, api, _) = await viewer()
        api.putFailures = 1
        _ = store.receive(json: message("answers", #""answers": {"d1": "C"}"#))
        await waitUntil { !store.isUnsaved }
        XCTAssertEqual(api.putAttempts, 2)
        XCTAssertEqual(api.putAnswers, [["d1": .string("C")]])
    }

    @MainActor
    func testLeavingWritesWhatIsStillResting() async {
        let api = FakeReportsApi()
        let store = ReportViewerStore(
            reportID: "r1", api: api, drafts: FakeComposerDrafts(), scheduler: NeverScheduler())
        api.detail = report("r1", created: "2026-11-01")
        await store.load()
        _ = store.receive(json: message("answers", #""answers": {"d1": "Z"}"#))
        XCTAssertTrue(api.putAnswers.isEmpty)
        await store.leave()
        XCTAssertEqual(api.putAnswers, [["d1": .string("Z")]])
        XCTAssertFalse(store.isUnsaved)
    }

    @MainActor
    func testAddToMessagePutsTheTextIntoThatSessionsComposerUnsentWithANotice() async {
        let drafts = FakeComposerDrafts()
        drafts.texts["s1"] = "Earlier words"
        let (store, _, _) = await viewer(drafts: drafts)
        _ = store.receive(json: message("add-to-message", #""text": "Decision 1: A""#))
        XCTAssertEqual(drafts.texts["s1"], "Earlier words\n\nDecision 1: A")
        XCTAssertEqual(drafts.focusRequests, 1)
        XCTAssertEqual(store.notice?.sessionId, "s1")
        XCTAssertEqual(drafts.texts.count, 1, "no other session's draft is touched")
        store.dismissNotice()
        XCTAssertNil(store.notice)
    }

    @MainActor
    func testAddToMessageOfAReportWithoutASessionSaysThereIsNoMessage() async {
        let drafts = FakeComposerDrafts()
        let (store, _, _) = await viewer(report: report("r1", created: "2026-11-01", session: nil), drafts: drafts)
        _ = store.receive(json: message("add-to-message", #""text": "x""#))
        XCTAssertTrue(drafts.texts.isEmpty)
        XCTAssertNil(store.notice?.sessionId)
        XCTAssertNotNil(store.notice)
    }

    @MainActor
    func testDeletingTellsTheCaller() async {
        let (store, api, _) = await viewer()
        let gone = await store.delete()
        XCTAssertTrue(gone)
        XCTAssertTrue(store.isDeleted)
        XCTAssertEqual(api.deleted, ["r1"])
        api.deleteError = PaiError.transport("offline")
        let again = await store.delete()
        XCTAssertFalse(again)
        XCTAssertEqual(store.notice?.text, "The report could not be deleted.")
    }

    // MARK: Helpers

    private func report(
        _ id: String, created: String, session: String? = "s1", answers: [String: PaiJSONValue] = [:]
    ) -> DynamicReport {
        DynamicReport(
            id: id, title: "T \(id)", sessionId: session, sessionTitle: session == nil ? nil : "Session",
            url: "https://x/apps/reports/\(id)", answers: answers, createdAt: created, updatedAt: created)
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out")
    }
}

private struct InstantScheduler: DraftScheduler {
    func sleep(seconds: TimeInterval) async throws {}
}

private struct NeverScheduler: DraftScheduler {
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

@MainActor
private final class FakeComposerDrafts: ReportComposerDrafts {
    var texts: [String: String] = [:]
    var focusRequests = 0
    func draftText(for key: String) -> String { texts[key] ?? "" }
    func setDraftText(key: String, text: String) { texts[key] = text }
    func requestComposerFocus() { focusRequests += 1 }
}

private final class FakeReportsApi: DynamicReportsApiClient, @unchecked Sendable {
    var pages: [[DynamicReport]] = []
    var listCalls: [String?] = []
    var listError: Error?
    var detail: DynamicReport?
    var detailError: Error?
    var pageFetches: [String] = []
    var putAnswers: [[String: PaiJSONValue]] = []
    var putAttempts = 0
    var putFailures = 0
    var deleted: [String] = []
    var deleteError: Error?

    func listDynamicReports(before: String?) async throws -> [DynamicReport] {
        listCalls.append(before)
        if let listError { throw listError }
        return pages.isEmpty ? [] : pages.removeFirst()
    }

    func getDynamicReport(id: String) async throws -> DynamicReport {
        if let detailError { throw detailError }
        return try XCTUnwrap(detail)
    }

    func getDynamicReportPage(id: String) async throws -> String {
        pageFetches.append(id)
        if let detailError { throw detailError }
        return "<html>page</html>"
    }

    func putDynamicReportAnswers(id: String, answers: [String: PaiJSONValue]) async throws -> DynamicReport {
        putAttempts += 1
        if putFailures > 0 {
            putFailures -= 1
            throw PaiError.transport("offline")
        }
        putAnswers.append(answers)
        return try XCTUnwrap(detail)
    }

    func deleteDynamicReport(id: String) async throws {
        if let deleteError { throw deleteError }
        deleted.append(id)
    }
}
