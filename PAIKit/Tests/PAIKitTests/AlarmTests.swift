import Foundation
import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

/// Records every request and answers with a fixed status and body, so a test can read the method,
/// path and JSON the client really sent.
final class AlarmRecordingURLProtocol: URLProtocol {
    struct Seen: Equatable {
        let method: String
        let path: String
        let body: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [Seen] = []
    nonisolated(unsafe) private static var _reply = Data()

    static func configure(reply: String) {
        lock.lock()
        defer { lock.unlock() }
        _seen = []
        _reply = Data(reply.utf8)
    }

    static var seen: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return _seen
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlarmRecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            stream.close()
            data = collected
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        Self.lock.lock()
        Self._seen.append(Seen(method: request.httpMethod ?? "", path: request.url!.path, body: body))
        let reply = Self._reply
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The alarm wire shapes, the next-occurrence rule, the requests the client sends and what the
/// stores do with the answers.
final class AlarmTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ iso: String) -> Date { IsoTimestamp.date(from: iso)! }

    // MARK: Wire

    func testTheListDecodesAsTheContractNamesIt() throws {
        let list = try decode(AlarmListResponse.self, PaiFixtures.alarmList)
        XCTAssertEqual(list.alarms.map(\.source), [.ios, .watch])
        XCTAssertEqual(list.alarms[1].name, "Bahn nach Köln")
        XCTAssertEqual(list.ringing.first?.endsAt, "2026-08-31T22:31:00.801234+00:00")
        XCTAssertNotNil(list.alarms[0].fireDate)
        XCTAssertFalse(list.serverTime.isEmpty)
    }

    func testAnUnknownSourceDecodesInsteadOfFailingTheList() throws {
        let alarm = try decode(
            Alarm.self,
            #"{"id":"a","name":"x","fire_at":"2026-09-01T05:30:00+00:00","created_at":"2026-08-31T20:00:00+00:00","source":"toaster"}"#
        )
        XCTAssertEqual(alarm.source, .unrecognized("toaster"))
    }

    func testWatchKeyFixturesDecode() throws {
        let keys = try decode([WatchKey].self, PaiFixtures.watchKeys)
        XCTAssertEqual(keys.map(\.hint), ["pw_aB3x", "pw_Q7mZ"])
        XCTAssertNil(keys[1].lastUsedAt)
        let created = try decode(WatchKeyCreated.self, PaiFixtures.watchKeyCreated)
        XCTAssertTrue(created.key.hasPrefix("pw_"))
    }

    func testRingSettingsRideTheUserSettingsWithTheContractsNames() throws {
        let settings = try decode(UserSettings.self, PaiFixtures.mySettings)
        XCTAssertEqual(settings.alarmRingIntervalS, 5)
        XCTAssertEqual(settings.alarmRingDurationS, 60)

        let data = try JSONEncoder().encode(UserSettingsPatch(alarmRingIntervalS: 10))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(json, ["alarm_ring_interval_s": 10])
        XCTAssertEqual(UserSettingsPatch(alarmRingDurationS: 90).applied(to: settings).alarmRingDurationS, 90)
    }

    func testTheAlarmPushChannelIsServedAndMutable() throws {
        let channels = try decode(PushChannelsResponse.self, PaiFixtures.pushChannels)
        XCTAssertTrue(channels.channels.contains { $0.id == "alarm" })
    }

    // MARK: Next occurrence

    func testAnAheadTimeFiresToday() throws {
        let berlin = calendar("Europe/Berlin")
        let now = date("2026-09-01T05:00:00+00:00")  // 07:00 in Berlin
        let fire = try XCTUnwrap(AlarmTime.nextOccurrence(hour: 7, minute: 30, after: now, calendar: berlin))
        XCTAssertEqual(AlarmTime.wireString(fire), "2026-09-01T05:30:00+00:00")
    }

    func testAPassedTimeFiresTomorrow() throws {
        let berlin = calendar("Europe/Berlin")
        let now = date("2026-09-01T05:00:00+00:00")  // 07:00 in Berlin
        let fire = try XCTUnwrap(AlarmTime.nextOccurrence(hour: 6, minute: 45, after: now, calendar: berlin))
        XCTAssertEqual(AlarmTime.wireString(fire), "2026-09-02T04:45:00+00:00")
    }

    func testTheCurrentMinuteIsNotAheadOfItself() throws {
        let berlin = calendar("Europe/Berlin")
        let now = date("2026-09-01T05:00:00+00:00")
        let fire = try XCTUnwrap(AlarmTime.nextOccurrence(hour: 7, minute: 0, after: now, calendar: berlin))
        XCTAssertEqual(AlarmTime.wireString(fire), "2026-09-02T05:00:00+00:00")
    }

    func testTheOffsetFollowsTheZoneAcrossTheDstChange() throws {
        let berlin = calendar("Europe/Berlin")
        let now = date("2026-10-24T20:00:00+00:00")  // the evening before clocks go back
        let fire = try XCTUnwrap(AlarmTime.nextOccurrence(hour: 7, minute: 0, after: now, calendar: berlin))
        XCTAssertEqual(AlarmTime.wireString(fire), "2026-10-25T06:00:00+00:00")
    }

    func testTheTitleCarriesTheClock() {
        XCTAssertEqual(AlarmTime.title("Wecker"), "⏰ Wecker")
    }

    // MARK: Requests

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: AlarmRecordingURLProtocol.makeSession())
    }

    func testCreateSendsTheContractBody() async throws {
        AlarmRecordingURLProtocol.configure(reply: PaiFixtures.alarmCreated)
        _ = try await makeClient().createAlarm(
            AlarmCreate(fireAt: "2026-09-01T05:30:00+00:00", name: "Bahn", source: .ios))
        XCTAssertEqual(
            AlarmRecordingURLProtocol.seen,
            [
                .init(
                    method: "POST", path: "/api/alarm",
                    body: ["fire_at": "2026-09-01T05:30:00+00:00", "name": "Bahn", "source": "ios"])
            ])
    }

    func testAnEmptyNameIsOmittedSoTheServerDefaultApplies() async throws {
        AlarmRecordingURLProtocol.configure(reply: PaiFixtures.alarmCreated)
        _ = try await makeClient().createAlarm(AlarmCreate(fireAt: "2026-09-01T05:30:00+00:00"))
        XCTAssertEqual(AlarmRecordingURLProtocol.seen.first?.body["name"], nil)
    }

    func testTheActionsUseTheContractsMethodsAndPaths() async throws {
        AlarmRecordingURLProtocol.configure(reply: "")
        let client = try makeClient()
        try await client.deleteAlarm(id: "a1")
        try await client.dismissAlarm(id: "a1")
        try await client.dismissRingingAlarms()
        try await client.revokeWatchKey(id: "k1")
        XCTAssertEqual(
            AlarmRecordingURLProtocol.seen.map { "\($0.method) \($0.path)" },
            [
                "DELETE /api/alarm/a1", "POST /api/alarm/a1/dismiss", "POST /api/alarm/dismiss",
                "DELETE /api/watch-keys/k1",
            ])
    }

    func testCreatingAWatchKeySendsOnlyItsName() async throws {
        AlarmRecordingURLProtocol.configure(reply: PaiFixtures.watchKeyCreated)
        _ = try await makeClient().createWatchKey(name: "fenix 8")
        XCTAssertEqual(
            AlarmRecordingURLProtocol.seen, [.init(method: "POST", path: "/api/watch-keys", body: ["name": "fenix 8"])])
    }

    // MARK: Stores

    func testAddingAnAlarmSendsTheNextOccurrenceAndRereadsTheList() async throws {
        let api = FakeAlarmApi()
        let store = await AlarmStore(api: api)
        let ok = await store.add(
            hour: 6, minute: 45, name: "  ", now: date("2026-09-01T05:00:00+00:00"), calendar: calendar("Europe/Berlin")
        )
        XCTAssertTrue(ok)
        let created = await api.created
        XCTAssertEqual(created.map(\.fireAt), ["2026-09-02T04:45:00+00:00"])
        XCTAssertEqual(created.map(\.name), [nil])
        let alarms = await store.alarms
        XCTAssertEqual(alarms.count, 2)
    }

    func testAFailedSaveKeepsTheErrorAndSaysSo() async {
        let api = FakeAlarmApi()
        await api.failNext(.detail("fire_at must be in the future", statusCode: 422))
        let store = await AlarmStore(api: api)
        let ok = await store.add(hour: 7, minute: 0, name: "")
        XCTAssertFalse(ok)
        let message = await store.errorMessage
        XCTAssertEqual(message, "fire_at must be in the future")
    }

    func testDismissingCallsTheServerThenShowsItsAnswer() async throws {
        let api = FakeAlarmApi()
        let store = await AlarmStore(api: api)
        await store.load()
        let current = await store.ringing
        let ringing = try XCTUnwrap(current.first)
        await store.dismiss(ringing)
        let dismissed = await api.dismissed
        XCTAssertEqual(dismissed, [ringing.id])
        let after = await store.ringing
        XCTAssertTrue(after.isEmpty)
    }

    func testAFailedLoadKeepsWhatWasShown() async {
        let api = FakeAlarmApi()
        let store = await AlarmStore(api: api)
        await store.load()
        await api.failNext(.transport("offline"))
        await store.load()
        let alarms = await store.alarms
        XCTAssertEqual(alarms.count, 2)
        let message = await store.errorMessage
        XCTAssertNotNil(message)
    }

    func testAWatchKeyIsHeldOnlyUntilAcknowledged() async {
        let api = FakeWatchKeysApi()
        let store = await WatchKeysStore(api: api)
        await store.create(name: " fenix 8 ")
        let created = await store.justCreated
        XCTAssertEqual(created?.key, "pw_plain")
        let name = await api.createdNames
        XCTAssertEqual(name, ["fenix 8"])
        await store.acknowledgeCreated()
        let after = await store.justCreated
        XCTAssertNil(after)
        // The list never carries the plain key.
        let keys = await store.keys
        XCTAssertEqual(keys.map(\.hint), ["pw_aB3x"])
    }

    /// The sheet that shows the plain key reads `justCreated`; the list reload that follows a
    /// create, and a later revoke with its own reload, must leave it until it is acknowledged.
    func testTheCreatedKeySurvivesTheReloadsThatFollow() async throws {
        let api = FakeWatchKeysApi()
        let store = await WatchKeysStore(api: api)
        await store.create(name: "fenix 8")
        await store.load()
        let listed = await store.keys
        await store.revoke(try XCTUnwrap(listed.first))
        let created = await store.justCreated
        XCTAssertEqual(created?.key, "pw_plain")
    }

    /// `GET /api/watch-keys?everyone=true` adds `user_id` and `display_name` to each row; a list
    /// that ever carries them must still decode.
    func testTheEveryoneListShapeDecodes() throws {
        let keys = try decode(
            [WatchKey].self,
            #"[{"id":"4f0c6a5e-0000-4c1a-8f30-2b7e5c918d01","name":"fenix 8","hint":"pw_aB3x","created_at":"2026-08-20T09:00:00.123456+00:00","last_used_at":null,"user_id":"9b1e0d2a-0000-4c1a-8f30-2b7e5c918d02","display_name":"Chiara"}]"#
        )
        XCTAssertEqual(keys.map(\.name), ["fenix 8"])
    }

    func testABlankKeyNameCreatesNothing() async {
        let api = FakeWatchKeysApi()
        let store = await WatchKeysStore(api: api)
        await store.create(name: "   ")
        let names = await api.createdNames
        XCTAssertEqual(names, [])
    }

    func testRevokingReadsTheListAgain() async throws {
        let api = FakeWatchKeysApi()
        let store = await WatchKeysStore(api: api)
        await store.load()
        let listed = await store.keys
        let key = try XCTUnwrap(listed.first)
        await store.revoke(key)
        let revoked = await api.revoked
        XCTAssertEqual(revoked, [key.id])
        let keys = await store.keys
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: Deep link and capabilities

    func testTheControlsLinkAndTheUniversalLinkOpenTheApp() {
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://alarm")!), .alarm(id: nil))
        XCTAssertEqual(DeepLink.from(webURL: URL(string: "https://pai.example/apps/alarm")!), .alarm(id: nil))
        XCTAssertNil(DeepLink.from(url: URL(string: "pai://alarm/extra")!))
        XCTAssertEqual(DeepLink.alarm(id: nil).url, URL(string: "pai://alarm"))
        XCTAssertEqual(DeepLink.alarm(id: nil).routes, [.alarm])
    }

    func testAnAlarmPushNamesItsAlarmAndBeatsTheOtherKeys() {
        XCTAssertEqual(DeepLink.from(payload: ["pai_alarm_id": "a1"]), .alarm(id: "a1"))
        XCTAssertEqual(
            DeepLink.from(payload: ["pai_alarm_id": "a1", "pai_notification_id": "n1"]), .alarm(id: "a1"))
        XCTAssertEqual(DeepLink.from(payload: ["pai_notification_id": "n1"]), .notification(id: "n1"))
    }

    func testAnAlarmLinkClosesWhateverIsPresented() {
        XCTAssertTrue(DeepLink.alarm(id: "a1").dismissesOverlays)
    }

    func testGuestsMayUseAlarmsAndPush() {
        for role in [UserRole.owner, .guest] {
            let capabilities = Capabilities(role: role)
            XCTAssertTrue(capabilities.canOpenAlarm)
            XCTAssertTrue(capabilities.canRegisterPush)
        }
        for capabilities in [Capabilities.unknown, Capabilities(role: .unrecognized("admin"))] {
            XCTAssertFalse(capabilities.canOpenAlarm)
            XCTAssertFalse(capabilities.canRegisterPush)
        }
    }
}

private actor FakeAlarmApi: AlarmApiClient {
    private var response = try! JSONDecoder().decode(
        AlarmListResponse.self, from: Data(PaiFixtures.alarmList.utf8))
    private var failure: PaiError?
    private(set) var created: [AlarmCreate] = []
    private(set) var dismissed: [String] = []

    func failNext(_ error: PaiError) { failure = error }

    private func check() throws {
        if let failure {
            self.failure = nil
            throw failure
        }
    }

    func listAlarms() async throws -> AlarmListResponse {
        try check()
        return response
    }

    func createAlarm(_ alarm: AlarmCreate) async throws -> Alarm {
        try check()
        created.append(alarm)
        return try JSONDecoder().decode(Alarm.self, from: Data(PaiFixtures.alarmCreated.utf8))
    }

    func deleteAlarm(id: String) async throws { try check() }

    func dismissAlarm(id: String) async throws {
        try check()
        dismissed.append(id)
        response = AlarmListResponse(alarms: response.alarms, ringing: [], serverTime: response.serverTime)
    }

    func dismissRingingAlarms() async throws { try check() }
}

private actor FakeWatchKeysApi: WatchKeysApiClient {
    private var keys = [
        WatchKey(id: "k1", name: "fenix 8", hint: "pw_aB3x", createdAt: "2026-08-20T09:00:00+00:00", lastUsedAt: nil)
    ]
    private(set) var createdNames: [String] = []
    private(set) var revoked: [String] = []

    func listWatchKeys() async throws -> [WatchKey] { keys }

    func createWatchKey(name: String) async throws -> WatchKeyCreated {
        createdNames.append(name)
        return WatchKeyCreated(id: "k2", name: name, key: "pw_plain")
    }

    func revokeWatchKey(id: String) async throws {
        revoked.append(id)
        keys.removeAll { $0.id == id }
    }
}

/// The fixture corpus remembers what the watch-key probe creates and revokes, so the list read
/// after each shows it.
final class WatchKeyFixtureStateTests: XCTestCase {
    func testAListReadAfterCreateAndRevokeShowsBoth() throws {
        let state = WatchKeyFixtureState()
        func names() throws -> [String] {
            try JSONDecoder().decode([WatchKey].self, from: state.listBody()).map(\.id)
        }
        XCTAssertEqual(try names(), ["k1", "k2"])
        state.create()
        XCTAssertEqual(try names(), ["k3", "k1", "k2"])
        state.revoke("k1")
        XCTAssertEqual(try names(), ["k3", "k2"])
    }

    func testTheProbeFlagIsRead() {
        XCTAssertEqual(
            PaiFixtureLaunch.requestedWatchKeyProbe(arguments: ["-PaiFixtureWatchKeys", "revoke"]), "revoke")
        XCTAssertNil(PaiFixtureLaunch.requestedWatchKeyProbe(arguments: []))
    }
}

final class AlarmDeliveryTests: XCTestCase {
    private let delivered = [
        AlarmDelivery.Delivered(identifier: "n1", alarmID: "a1"),
        AlarmDelivery.Delivered(identifier: "n2", alarmID: "a1"),
        AlarmDelivery.Delivered(identifier: "n3", alarmID: "a2"),
        AlarmDelivery.Delivered(identifier: "n4", alarmID: nil),
    ]

    /// The payload exactly as the backend sends a stopped ring.
    func testTheStoppedPushNamesItsAlarm() {
        XCTAssertEqual(
            AlarmDelivery.stoppedAlarmID(in: ["pai_kind": "alarm_stopped", "pai_alarm_id": "a1"]), "a1")
        XCTAssertNil(AlarmDelivery.stoppedAlarmID(in: ["pai_alarm_id": "a1"]))
        XCTAssertNil(AlarmDelivery.stoppedAlarmID(in: ["pai_kind": "alarm_stopped"]))
        XCTAssertNil(AlarmDelivery.stoppedAlarmID(in: ["pai_kind": "read_sync", "pai_alarm_id": "a1"]))
    }

    func testAStoppedRingTakesOnlyItsOwnBanners() {
        XCTAssertEqual(AlarmDelivery.identifiers(of: "a1", in: delivered), ["n1", "n2"])
    }

    func testOpeningTheAppKeepsRingingBannersAndNonAlarmOnes() {
        XCTAssertEqual(AlarmDelivery.identifiersToClear(delivered: delivered, ringingIDs: ["a2"]), ["n1", "n2"])
        XCTAssertEqual(AlarmDelivery.identifiersToClear(delivered: delivered, ringingIDs: []), ["n1", "n2", "n3"])
    }
}
