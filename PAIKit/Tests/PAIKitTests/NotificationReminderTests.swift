import Foundation
import XCTest

@testable import PAIKit

/// A reminder in the feed: the kind decodes, an unknown kind never fails the page, and every read
/// of the feed asks for the kind so the server serves it as itself.
final class NotificationReminderTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    func testTheFeedFixtureHoldsAReminderRowWithItsName() throws {
        let page = try JSONDecoder().decode(
            NotificationsResponse.self, from: PaiFixtures.data(PaiFixtures.notifications))
        let row = try XCTUnwrap(page.notifications.first { $0.kind == .reminder })
        XCTAssertEqual(row.title, "Library book")
        XCTAssertEqual(row.reminderName, "office-library-book")
        XCTAssertEqual(row.reminderId, PaiFixtures.reminderFixtureId)
        XCTAssertNil(row.sessionId)
        XCTAssertEqual(page.notifications.filter { $0.reminderId != nil }.count, 1)
    }

    func testAnUnknownKindDecodesAsAnAgentRowInsteadOfFailingThePage() throws {
        let json = """
            {"unread": 1, "has_more": false, "notifications": [
              {"id": "n1", "kind": "telepathy", "title": "t", "body": "b", "created_at": "2026-01-01T00:00:00Z",
               "read_at": null, "session_id": null, "session_title": null, "anchor": null, "alert": null},
              {"id": "n2", "kind": "alert", "title": "t", "body": "b", "created_at": "2026-01-01T00:00:00Z",
               "read_at": null, "session_id": null, "session_title": null, "anchor": null, "alert": null}]}
            """
        let page = try JSONDecoder().decode(NotificationsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(page.notifications.map(\.kind), [.agent, .alert])
    }

    func testTheFeedAndTheSingleRowAskForReminders() async throws {
        let client = try makeClient()
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: PaiFixtures.data(PaiFixtures.notifications))
        _ = try await client.getNotifications(kind: .reminder)
        var query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("accept_kinds=reminder"), query)
        XCTAssertTrue(query.contains("kind=reminder"), query)

        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: PaiFixtures.data(PaiFixtures.notificationDetail))
        _ = try await client.getNotification(id: "n1")
        query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertEqual(query, "accept_kinds=reminder")
    }

    @MainActor
    func testTheStreamAsksForRemindersAndDecodesOne() async throws {
        let notificationJson = """
            {"notification":{"id":"n1","kind":"reminder","title":"Library book","body":"b",\
            "created_at":"2026-01-01T00:00:00Z","read_at":null,"session_id":null,"session_title":null,\
            "anchor":null,"alert":null,"reminder_id":"r1","reminder_name":"office-library-book"},"unread":1}
            """
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:],
            body: Data("event: notification\r\ndata: \(notificationJson)\r\n\r\n".utf8))
        let factory = try PaiRequestFactory(
            baseURL: "https://stub.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let signal = PaiStreamConnectionSignal()
        var seen: [SseNotificationEvent] = []
        let callbacks = PaiNotificationStreamClient.Callbacks(
            onNotification: { event in
                seen.append(event)
                Task { await signal.fire() }
            },
            onRead: { _ in }, onActivity: {}, onConnected: {}, onDisconnected: {})
        let client = PaiNotificationStreamClient(
            requestFactory: factory, callbacks: callbacks,
            urlSessionConfiguration: PaiStubURLProtocol.makeConfiguration())
        client.connect()
        await signal.wait()
        client.disconnect()
        XCTAssertEqual(seen.first?.notification.kind, .reminder)
        XCTAssertEqual(seen.first?.notification.reminderId, "r1")
        let query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertEqual(query, "accept_kinds=reminder")
    }

    func testOnlyTheOwnerIsOfferedTheRemindersSegment() {
        XCTAssertTrue(NotificationFilter.available(for: Capabilities(role: .owner)).contains(.reminder))
        XCTAssertFalse(NotificationFilter.available(for: Capabilities(role: .guest)).contains(.reminder))
        XCTAssertFalse(NotificationFilter.available(for: .unknown).contains(.reminder))
        XCTAssertEqual(NotificationFilter.reminder.kind, .reminder)
        XCTAssertTrue(Capabilities(role: .owner).canOpenReminders)
        XCTAssertFalse(Capabilities(role: .guest).canOpenReminders)
    }

    func testAReminderRouteIsASchedulerSurfaceAndHasAFixtureName() {
        XCTAssertTrue(Route.reminder(id: "r").isSessionSurface)
        XCTAssertEqual(Route.named("reminder", sessionID: "s"), .reminder(id: Route.fixtureReminderId))
        XCTAssertTrue(Route.namedScreens.contains("reminder"))
        XCTAssertNotEqual(Route.reminder(id: "a"), Route.reminder(id: "b"))
    }
}
