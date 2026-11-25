import XCTest

@testable import PAIKit

/// Not `@MainActor` — see `SettingsSmtpSettingsStoreTests` for the Linux discovery crash that
/// forbids it. Every store access is awaited instead.
final class DebugRecordingsStoreTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private static func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private static let listBody = """
        {"enabled": true, "recordings": [{
          "id": "6f1c2d3e-0000-4000-8000-000000000001", "kind": "call_dictation",
          "engine": "elevenlabs_realtime", "model": "scribe_v2_realtime", "transport": "ios",
          "device": "iPhone · iOS 26.0", "mics": ["iPhone Microphone", "AirPods Pro"],
          "bus_id": "6f1c2d3e-0000-4000-8000-0000000000aa", "session_id": null, "session_title": null,
          "take_id": null, "sample_rate": 16000, "encoding": "pcm_s16le", "channels": 1,
          "started_at": "2026-10-03T10:15:02.123456+00:00", "ended_at": null, "duration_ms": 4200,
          "byte_count": 134400, "peak_dbfs": -3.5, "rms_dbfs": null, "clipped_samples": 0,
          "status": "recording", "end_reason": null, "truncated": false,
          "events": [{"sample": 0, "kind": "mic", "detail": {"mic": "AirPods Pro"}},
                     {"sample": 32000, "kind": "wake_score", "detail": {"score": 0.31}},
                     {"sample": 64000, "kind": "reopen"}]
        }]}
        """

    private func stub(_ status: Int, _ body: String) {
        PaiStubURLProtocol.stub = .init(
            statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    /// Event details carry strings and numbers side by side, and an event may have none — one
    /// shape the decoder gets wrong fails the whole list.
    func testTheListDecodesWithMixedEventDetails() async throws {
        stub(200, Self.listBody)
        let store = await DebugRecordingsStore(apiClient: try Self.makeClient())
        await store.load()
        let recordings = await store.recordings
        let enabled = await store.enabled
        XCTAssertEqual(enabled, true)
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings.first?.mics, ["iPhone Microphone", "AirPods Pro"])
        XCTAssertEqual(recordings.first?.events[1].detail?["score"], .number(0.31))
        XCTAssertNil(recordings.first?.events[2].detail)
    }

    /// The clipping badge is the server's judgement: a few full-scale samples on a loud word are
    /// not clipping, and a server that does not judge it shows none.
    func testTheClippingBadgeFollowsTheServedJudgementOnly() throws {
        func recording(_ extra: String) throws -> DebugRecording {
            let json = Self.listBody.replacingOccurrences(of: #""clipped_samples": 0,"#, with: extra)
            return try XCTUnwrap(
                JSONDecoder().decode(DebugRecordingList.self, from: Data(json.utf8)).recordings.first)
        }
        XCTAssertFalse(try recording(#""clipped_samples": 12, "clipping": false,"#).showsClippingBadge)
        XCTAssertTrue(try recording(#""clipped_samples": 900, "clipping": true,"#).showsClippingBadge)
        XCTAssertFalse(try recording(#""clipped_samples": 900,"#).showsClippingBadge, "an older server shows no badge")
    }

    /// A recording made from an uploaded take has no device, mics or session, and its own engine,
    /// transport and end reason strings — it must list like any other.
    func testAnUploadedTakeRecordingDecodes() async throws {
        stub(
            200,
            """
            {"enabled": true, "recordings": [{
              "id": "6f1c2d3e-0000-4000-8000-000000000002", "kind": "dictation",
              "engine": "elevenlabs_batch", "model": "scribe_v2", "transport": "upload",
              "device": null, "mics": [],
              "bus_id": "6f1c2d3e-0000-4000-8000-0000000000bb", "session_id": null, "session_title": null,
              "take_id": "T1", "sample_rate": 16000, "encoding": "pcm_s16le", "channels": 1,
              "started_at": "2026-10-03T10:15:02.123456+00:00", "ended_at": "2026-10-03T10:15:09.123456+00:00",
              "duration_ms": 7000, "byte_count": 224000, "peak_dbfs": -12.3, "rms_dbfs": -31.5,
              "clipped_samples": 0, "status": "complete", "end_reason": "uploaded", "truncated": false,
              "events": []
            }]}
            """)
        let store = await DebugRecordingsStore(apiClient: try Self.makeClient())
        await store.load()
        let recording = await store.recordings.first
        XCTAssertEqual(recording?.engine, "elevenlabs_batch")
        XCTAssertEqual(recording?.transport, "upload")
        XCTAssertEqual(recording?.endReason, "uploaded")
        XCTAssertNil(recording?.device)
        XCTAssertEqual(recording?.mics, [])
    }

    /// Keeping recordings is the instance setting `debug_recordings_enabled`: the switch writes it
    /// there and shows what the server answers, not what was asked.
    func testTheSwitchWritesTheInstanceSetting() async throws {
        stub(200, #"{"instance": {"debug_recordings_enabled": false}}"#)
        let store = await DebugRecordingsStore(apiClient: try Self.makeClient())

        await store.setEnabled(false)

        let request = try XCTUnwrap(PaiStubURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/settings/instance")
        let body = try XCTUnwrap(
            PaiStubURLProtocol.capturedBody.flatMap { try? JSONSerialization.jsonObject(with: $0) })
        XCTAssertEqual((body as? [String: Bool]), ["debug_recordings_enabled": false])
        let enabled = await store.enabled
        XCTAssertEqual(enabled, false)
    }

    /// A recording still being written is refused by the backend; it must stay listed.
    func testARefusedDeleteKeepsTheRecordingListed() async throws {
        stub(200, Self.listBody)
        let store = await DebugRecordingsStore(apiClient: try Self.makeClient())
        await store.load()
        stub(409, #"{"detail": "still recording"}"#)
        await store.delete(id: "6f1c2d3e-0000-4000-8000-000000000001")
        let count = await store.recordings.count
        let error = await store.error
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(error)
    }

    /// The upload queue drops a run on exactly this answer, so it must come back as an outcome
    /// rather than as an error the queue would retry forever.
    func testATakeForARunDeletedElsewhereComesBackAsRunGone() async throws {
        stub(404, #"{"detail": "no such run"}"#)
        let outcome = try await Self.makeClient().putWakeWordTake(
            runId: "r", takeId: "t", wav: Data([0, 0]), index: 1, recordedAt: "2026-10-03T10:00:00Z", durationMs: 1)
        XCTAssertEqual(outcome, .runGone)
    }

    /// Rows recorded before the OpenAI engine and the phone line went away still list, with a
    /// label for a value this build has no name for.
    func testARetiredEngineAndTransportStillDisplay() throws {
        let list = try JSONDecoder().decode(DebugRecordingList.self, from: Data(PaiFixtures.debugRecordings.utf8))
        let old = try XCTUnwrap(list.recordings.first { $0.engine == "openai_realtime" })
        XCTAssertEqual(old.engineLabel, "openai realtime")
        XCTAssertEqual(old.transportLabel, "twilio")
        let current = try XCTUnwrap(list.recordings.first { $0.engine == "elevenlabs_realtime" })
        XCTAssertEqual(current.engineLabel, "ElevenLabs")
    }
}
