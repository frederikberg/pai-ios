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
    func getMeTasks(date: String?, fresh: Bool) async throws -> MeTasks { throw PaiError.transport("unused") }
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

/// The diary's draft must never need the network: every call fails the test that makes it.
private struct NoDraftRoutes: DraftsFetching {
    func getDrafts() async throws -> [Draft] { [] }
    func putDraft(
        key: String, text: String, deviceId: String?, sessionType: String?, workingDir: String?, model: String?,
        thinking: String?, noMemory: Bool?
    ) async throws -> DraftWriteResult {
        XCTFail("a diary draft reached putDraft")
        throw PaiError.transport("unexpected")
    }
    func deleteDraft(key: String) async throws -> PaiDraftDeleteResult {
        XCTFail("a diary draft reached deleteDraft")
        throw PaiError.transport("unexpected")
    }
    func addDraftAttachment(key: String, file: PaiFileUpload, id: String) async throws -> DraftAttachment {
        throw PaiError.transport("unexpected")
    }
    func removeDraftAttachment(key: String, attachmentId: String) async throws {}
}

@MainActor
final class SelfReportStoreTests: XCTestCase {
    private func store(_ api: FakeSelfReportApi, _ storage: SettingsInMemoryKeyValueStore) -> SelfReportStore {
        // The words live in the draft store, which shares the storage like the app's does.
        let drafts = listedDraftStore(api: NoDraftRoutes(), localPersistence: storage)
        return SelfReportStore(api: api, storage: storage, drafts: drafts, makeId: { "id-1" })
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
        s.updateDraft {
            $0.text = "words"; $0.isPrivate = true
        }
        s.send()
        await s.flush()
        XCTAssertNotNil(s.items.first?.refusal)
        XCTAssertEqual(s.items.first?.waiting, false)
        s.putBack(id: "id-1")
        XCTAssertEqual(s.draft.text, "words")
        XCTAssertTrue(s.draft.isPrivate)
        XCTAssertTrue(s.items.isEmpty)
    }

    func testTheWordsLiveInTheDraftStoreAndTheRestInTheStoreAcrossARelaunch() async {
        let api = FakeSelfReportApi()
        let storage = SettingsInMemoryKeyValueStore()
        let first = store(api, storage)
        first.updateDraft {
            $0.text = "typed"
            $0.feel = "good"
            $0.isPrivate = true
        }
        let second = store(api, storage)
        XCTAssertEqual(second.draft, SelfReportDraft(text: "typed", feel: "good", isPrivate: true))

        // Text written the way a dictation take writes it shows up as the draft's words.
        let drafts = listedDraftStore(api: NoDraftRoutes(), localPersistence: storage)
        drafts.setDraftText(key: SelfReportStore.dictationKey, text: "stt-rec: spoken")
        let third = SelfReportStore(api: api, storage: storage, drafts: drafts)
        XCTAssertEqual(third.draft.text, "stt-rec: spoken")
        XCTAssertTrue(third.send())
        XCTAssertTrue(third.draft.isEmpty)
        XCTAssertEqual(drafts.draft(for: SelfReportStore.dictationKey).text, "")
    }
}
