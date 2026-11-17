import XCTest

@testable import PAIKit

@MainActor
private final class Reports {
    var sent: [Bool] = []
}

/// The phone's half of "no push while in use": what it reports, and the banner it shows instead.
@MainActor
final class PresenceAndArrivalTests: XCTestCase {

    private func notification(_ id: String, readAt: String? = nil) -> PaiNotification {
        PaiNotification(
            id: id, kind: .agent, title: "✅ done", body: "", createdAt: "2026-11-17T12:00:00+00:00",
            readAt: readAt, sessionId: nil, sessionTitle: nil, anchor: nil, alert: nil, taskId: nil,
            taskName: nil, runSlug: "Weather")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAnActiveAppKeepsReportingAndStopsWithOneInactiveReport() async {
        let reports = Reports()
        let reporter = PresenceReporter(
            report: { reports.sent.append($0) }, sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })

        reporter.setActive(true)
        await waitUntil { reports.sent.count >= 3 }
        XCTAssertEqual(Array(reports.sent.prefix(3)), [true, true, true])

        reporter.setActive(false)
        await waitUntil { reports.sent.last == false }
        let count = reports.sent.count
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports.sent.count, count)
        XCTAssertEqual(reports.sent.last, false)
    }

    func testAnArrivalShowsBrieflyAndANewerOneReplacesIt() async {
        let store = ArrivalBannerStore(sleep: { _ in try await Task.sleep(for: .milliseconds(200)) })

        store.show(notification("a"))
        XCTAssertEqual(store.current?.title, "Weather · ✅ done")
        try? await Task.sleep(for: .milliseconds(100))
        store.show(notification("b"))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.current?.id, "b")

        await waitUntil { store.current == nil }
        XCTAssertNil(store.current)
    }

    func testANotificationRecordedReadShowsNothing() async {
        let store = ArrivalBannerStore()
        store.show(notification("quiet", readAt: "2026-11-17T12:00:00+00:00"))
        XCTAssertNil(store.current)
    }

    func testAStreamEventFromAnOlderBackendReadsAsNotInUse() async throws {
        let json =
            #"{"notification": {"id": "n", "kind": "agent", "title": "t", "body": "", "#
            + #""created_at": "2026-11-17T12:00:00+00:00", "read_at": null, "session_id": null, "#
            + #""session_title": null, "anchor": null, "alert": null, "task_id": null, "task_name": null}, "#
            + #""unread": 1}"#
        let event = try JSONDecoder().decode(SseNotificationEvent.self, from: Data(json.utf8))
        XCTAssertFalse(event.inUse)
    }
}
