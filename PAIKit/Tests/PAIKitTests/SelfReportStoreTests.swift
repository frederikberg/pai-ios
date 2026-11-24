import XCTest

@testable import PAIKit

private actor FakeSelfReportApi: SelfReportApiClient {
    var failing = true
    var rejectWith: PaiError?
    private(set) var sentIds: [String] = []

    func setFailing(_ value: Bool) { failing = value }
    func setReject(_ error: PaiError?) { rejectWith = error }

    func getMeOverview(days: Int, end: String?) async throws -> MeOverview { throw PaiError.transport("unused") }
    func getMeDay(date: String) async throws -> MeDay { throw PaiError.transport("unused") }
    func getSelfReports(before: String?, limit: Int, feel: String?, privateOnly: Bool) async throws
        -> SelfReportPage
    { SelfReportPage(selfReports: []) }

    func createSelfReport(_ body: SelfReportCreateBody) async throws -> SelfReport {
        if let rejectWith { throw rejectWith }
        if failing { throw PaiError.transport("offline") }
        sentIds.append(body.id)
        return SelfReport(id: body.id, at: body.at, text: body.text, feel: nil, isPrivate: body.isPrivate)
    }

    func patchSelfReport(id: String, _ body: SelfReportPatchBody) async throws -> SelfReport {
        throw PaiError.transport("unused")
    }
    func deleteSelfReport(id: String) async throws {}
    func restoreSelfReport(id: String) async throws {}
}

@MainActor
final class SelfReportStoreTests: XCTestCase {
    private func store(_ api: FakeSelfReportApi, _ storage: SettingsInMemoryKeyValueStore) -> SelfReportStore {
        SelfReportStore(api: api, storage: storage, makeId: { "id-1" })
    }

    func testAnEntryWrittenOfflineSurvivesARelaunchAndIsSentUnderTheSameId() async {
        let api = FakeSelfReportApi()
        let storage = SettingsInMemoryKeyValueStore()
        let first = store(api, storage)
        first.updateDraft { $0.text = "slept badly" }
        XCTAssertTrue(first.send())
        await first.flush()
        XCTAssertTrue(first.draft.isEmpty)
        XCTAssertEqual(first.items.map(\.report.id), ["id-1"])
        XCTAssertTrue(first.items[0].waiting)

        // A new process finds the entry in storage, and the network is back.
        await api.setFailing(false)
        let second = store(api, storage)
        XCTAssertEqual(second.pending.count, 1)
        await second.flush()
        let sent = await api.sentIds
        XCTAssertEqual(sent, ["id-1"])
        XCTAssertTrue(second.pending.isEmpty)
        XCTAssertFalse(second.items[0].waiting)
    }

    func testEmptyDraftIsNoEntryButAFaceAloneIs() {
        let s = store(FakeSelfReportApi(), SettingsInMemoryKeyValueStore())
        s.updateDraft { $0.text = "   \n" }
        XCTAssertFalse(s.send())
        s.updateDraft { $0.feel = "good" }
        XCTAssertTrue(s.send())
    }

    func testARefusedEntryStaysVisibleAndCanBePutBackInTheComposer() async {
        let api = FakeSelfReportApi()
        await api.setReject(PaiError.detail("bad", statusCode: 422))
        let s = store(api, SettingsInMemoryKeyValueStore())
        s.updateDraft { $0.text = "words"; $0.isPrivate = true }
        s.send()
        await s.flush()
        XCTAssertNotNil(s.items.first?.refusal)
        XCTAssertEqual(s.items.first?.waiting, false)
        s.putBack(id: "id-1")
        XCTAssertEqual(s.draft.text, "words")
        XCTAssertTrue(s.draft.isPrivate)
        XCTAssertTrue(s.items.isEmpty)
    }
}
