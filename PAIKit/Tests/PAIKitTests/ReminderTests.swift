import XCTest

@testable import PAIKit

private actor FakeReminderApi: ReminderListApiClient, ReminderDetailApiClient {
    var reminders: [Reminder] = []
    var detail: Reminder?
    var failure: Error?
    private(set) var calls: [String] = []
    private(set) var testedWith: [(ReminderTestEvent?, Bool)] = []

    func set(reminders: [Reminder]) { self.reminders = reminders }
    func set(detail: Reminder?) { self.detail = detail }
    func fail(with error: Error?) { failure = error }

    func listReminders() async throws -> [Reminder] {
        calls.append("list")
        if let failure { throw failure }
        return reminders
    }

    func getReminder(ref: String) async throws -> Reminder {
        calls.append("get")
        if let failure { throw failure }
        return try XCTUnwrap(detail)
    }

    func setReminderPaused(ref: String, paused: Bool) async throws -> Reminder {
        calls.append(paused ? "pause" : "unpause")
        if let failure { throw failure }
        let current = try XCTUnwrap(detail)
        let next = Reminder(
            id: current.id, name: current.name, title: current.title, trigger: current.trigger,
            state: paused ? .paused : .armed, pausedReason: paused ? "user" : nil)
        detail = next
        return next
    }

    func resumeReminder(ref: String) async throws -> Reminder {
        calls.append("resume")
        if let failure { throw failure }
        let current = try XCTUnwrap(detail)
        let next = Reminder(
            id: current.id, name: current.name, title: current.title, trigger: current.trigger, state: .armed)
        detail = next
        return next
    }

    func deleteReminder(ref: String) async throws {
        calls.append("delete")
        if let failure { throw failure }
    }

    func testReminder(ref: String, event: ReminderTestEvent?, notify: Bool) async throws -> ReminderTestResult {
        calls.append("test")
        testedWith.append((event, notify))
        if let failure { throw failure }
        return try JSONDecoder().decode(ReminderTestResult.self, from: PaiFixtures.data(PaiFixtures.reminderTested))
    }
}

/// The reminder wire shape, its wording, the calls made for it and what the list and detail stores
/// do with the answers.
final class ReminderTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func decodeList() throws -> [Reminder] {
        try JSONDecoder().decode(ReminderListResponse.self, from: PaiFixtures.data(PaiFixtures.reminders)).reminders
    }

    private func decodeDetail() throws -> Reminder {
        try JSONDecoder().decode(Reminder.self, from: PaiFixtures.data(PaiFixtures.reminderDetail))
    }

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private func stub(_ json: String) {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    // MARK: Wire

    func testTheListFixtureDecodesEveryKindOfTrigger() throws {
        let reminders = try decodeList()
        XCTAssertEqual(
            reminders.map(\.name), ["office-library-book", "door-bins", "page-date", "status-page", "parcel-pickup"])
        XCTAssertEqual(reminders[0].trigger.kind, .place)
        XCTAssertEqual(reminders[0].trigger.place, "Office")
        XCTAssertEqual(reminders[0].trigger.on, "enter")
        XCTAssertEqual(reminders[1].trigger.kind, .ha)
        XCTAssertEqual(reminders[1].trigger.entityId, "binary_sensor.front_door")
        XCTAssertEqual(reminders[1].trigger.from, "off")
        XCTAssertEqual(reminders[2].trigger.intervalSeconds, 3600)
        XCTAssertEqual(reminders[3].mode, .repeating)
        XCTAssertEqual(reminders[3].state, .failing)
        XCTAssertEqual(reminders[3].consecutiveFailures, 3)
        XCTAssertEqual(reminders[4].state, .fired)
        XCTAssertNil(reminders[0].events, "the list shape carries no history")
    }

    func testTheDetailFixtureCarriesScriptResultAndHistory() throws {
        let reminder = try decodeDetail()
        XCTAssertEqual(reminder.scriptRuntime, "bun")
        XCTAssertTrue(reminder.scriptSource?.contains("fetch") == true)
        XCTAssertEqual(reminder.lastResult?.cpuMs, 96)
        XCTAssertEqual(reminder.activeWindow?.days, [1, 2, 3, 4, 5])
        XCTAssertEqual(reminder.events?.map(\.kind), ["recovered", "failed", "created"])
        XCTAssertEqual(
            reminder.events?[1].note, "HTTP 503", "the failure's message is lifted out of the free-form detail")
        XCTAssertNil(reminder.events?[0].note)
    }

    func testAnUnknownStateModeAndTriggerKindDecodeInsteadOfFailingTheList() throws {
        let json = """
            {"reminders": [{"id": "x", "name": "n", "title": "t", "trigger": {"kind": "telepathy"},
             "mode": "sometimes", "state": "dreaming", "fired_count": 2.0, "cpu_ms_today": 12.5}]}
            """
        let reminder = try XCTUnwrap(
            JSONDecoder().decode(ReminderListResponse.self, from: Data(json.utf8)).reminders.first)
        XCTAssertEqual(reminder.trigger.kind, .unrecognized("telepathy"))
        XCTAssertEqual(reminder.mode, .unrecognized("sometimes"))
        XCTAssertEqual(reminder.state, .unrecognized("dreaming"))
        XCTAssertEqual(reminder.cpuMsToday, 13, "a fractional integer field rounds instead of failing the page")
        XCTAssertEqual(ReminderDisplay.stateLabel(reminder), "dreaming")
    }

    // MARK: Wording

    func testTheTriggerReadsAsTheSentenceItIs() throws {
        let reminders = try decodeList()
        XCTAssertEqual(ReminderDisplay.triggerLine(reminders[0].trigger), "arrive at Office")
        XCTAssertEqual(
            ReminderDisplay.triggerLine(reminders[1].trigger), "binary_sensor.front_door becomes on from off")
        XCTAssertEqual(ReminderDisplay.triggerLine(reminders[2].trigger), "checks every 60 min")
        XCTAssertEqual(ReminderDisplay.triggerLine(reminders[4].trigger), "leave Home after 5 min")
        XCTAssertEqual(ReminderDisplay.summaryLine(reminders[0]), "arrive at Office · once")
        XCTAssertEqual(ReminderDisplay.summaryLine(reminders[3]), "checks every 15 min · repeats")
    }

    func testTheStateSaysWhyAPauseHappened() {
        let user = Reminder(
            id: "a", name: "a", title: "a", trigger: ReminderTrigger(kind: .poll), state: .paused, pausedReason: "user")
        let budget = Reminder(
            id: "b", name: "b", title: "b", trigger: ReminderTrigger(kind: .poll), state: .paused,
            pausedReason: "budget")
        XCTAssertEqual(ReminderDisplay.stateLabel(user), "paused")
        XCTAssertEqual(ReminderDisplay.stateLabel(budget), "paused until midnight")
        XCTAssertEqual(ReminderDisplay.stateTone(budget), .muted)
    }

    func testAFailingReminderIsDrawnAsAnError() throws {
        let failing = try decodeList()[3]
        XCTAssertEqual(ReminderDisplay.stateTone(failing), .error)
        XCTAssertEqual(ReminderDisplay.stateLabel(failing), "failing")
    }

    func testTheDetailNamesTheLimitsAndTheHistoryLines() throws {
        let reminder = try decodeDetail()
        XCTAssertEqual(ReminderDisplay.limitLines(reminder), ["only 07:00–22:00 on Mon, Tue, Wed, Thu, Fri"])
        let failed = try XCTUnwrap(reminder.events?[1])
        XCTAssertTrue(
            ReminderDisplay.eventLine(failed).hasSuffix("failed: HTTP 503"), ReminderDisplay.eventLine(failed))
        XCTAssertNotNil(ReminderDisplay.expiryLine(reminder))
    }

    func testTheTestSummaryLeadsWithTheFailureThenTheVerdict() throws {
        var result = try JSONDecoder().decode(
            ReminderTestResult.self, from: PaiFixtures.data(PaiFixtures.reminderTested))
        XCTAssertEqual(ReminderDisplay.testSummary(result), "The check says nothing to report yet.")
        result = ReminderTestResult(
            ok: true, fire: true, title: "Bins", body: "", wouldNotify: false, reasonNot: "outside the active window",
            error: nil, exitCode: 0, stdoutTail: "", stderrTail: "", cpuMs: nil, durationMs: nil, notified: false)
        XCTAssertEqual(ReminderDisplay.testSummary(result), "Would not notify now: outside the active window")
        result = ReminderTestResult(
            ok: false, fire: nil, title: "", body: "", wouldNotify: false, reasonNot: nil, error: "timeout",
            exitCode: nil, stdoutTail: "", stderrTail: "", cpuMs: nil, durationMs: nil, notified: false)
        XCTAssertEqual(ReminderDisplay.testSummary(result), "The check failed: timeout")
    }

    // MARK: Calls

    func testTheRoutesHitTheContractsPathsAndBodies() async throws {
        let client = try makeClient()
        stub(PaiFixtures.reminders)
        _ = try await client.listReminders()
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/reminders")

        stub(PaiFixtures.reminderDetail)
        _ = try await client.getReminder(ref: "page-date")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/reminders/page-date")

        _ = try await client.setReminderPaused(ref: "page-date", paused: true)
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "PATCH")
        let patch = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(PaiStubURLProtocol.capturedBody)) as? [String: Bool])
        XCTAssertEqual(patch, ["paused": true])

        _ = try await client.resumeReminder(ref: "page-date")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/reminders/page-date/resume")

        try await client.deleteReminder(ref: "page-date")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/reminders/page-date")

        stub(PaiFixtures.reminderTested)
        _ = try await client.testReminder(
            ref: "page-date", event: ReminderTestEvent(place: "Office", on: "enter"), notify: true)
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/reminders/page-date/test")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(PaiStubURLProtocol.capturedBody)) as? [String: Any])
        XCTAssertEqual(body["notify"] as? Bool, true)
        XCTAssertEqual(body["event"] as? [String: String], ["place": "Office", "on": "enter"])
    }

    func testATestWithoutAnEventOmitsIt() async throws {
        let client = try makeClient()
        stub(PaiFixtures.reminderTested)
        _ = try await client.testReminder(ref: "x", event: nil, notify: false)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(PaiStubURLProtocol.capturedBody)) as? [String: Any])
        XCTAssertNil(body["event"])
    }

    func testANameWithASlashStaysOneSegment() {
        XCTAssertEqual(PaiApiClient.pathSegment("a/b c"), "a%2Fb%20c")
    }

    func testATestEventIsBuiltFromTheTriggerItSatisfies() throws {
        let reminders = try decodeList()
        XCTAssertEqual(
            ReminderTestEvent(satisfying: reminders[0].trigger), ReminderTestEvent(place: "Office", on: "enter"))
        XCTAssertEqual(
            ReminderTestEvent(satisfying: reminders[1].trigger),
            ReminderTestEvent(entityId: "binary_sensor.front_door", from: "off", to: "on"))
        XCTAssertNil(ReminderTestEvent(satisfying: reminders[2].trigger), "a script runs without an event")
    }

    // MARK: Stores

    @MainActor
    func testTheListLeadsWithWhatCanStillFire() async throws {
        let api = FakeReminderApi()
        await api.set(reminders: try decodeList())
        let store = ReminderListStore(api: api)
        await store.load()
        XCTAssertEqual(
            store.reminders.map(\.name),
            ["door-bins", "office-library-book", "page-date", "status-page", "parcel-pickup"])
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testAFailedListReadSaysSoAndKeepsWhatWasShown() async throws {
        let api = FakeReminderApi()
        await api.set(reminders: try decodeList())
        let store = ReminderListStore(api: api)
        await store.load()
        await api.fail(with: PaiError.detail("down", statusCode: 503))
        await store.load()
        XCTAssertEqual(store.errorMessage, "down")
        XCTAssertEqual(store.reminders.count, 5)
    }

    @MainActor
    func testAReminderDeletedSinceIsGoneRatherThanAnError() async {
        let api = FakeReminderApi()
        await api.fail(with: PaiError.detail("reminder not found", statusCode: 404))
        let store = ReminderDetailStore(id: "x", api: api)
        await store.load()
        XCTAssertTrue(store.isGone)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testPauseAndResumeFollowTheStateTheServerAnswers() async throws {
        let api = FakeReminderApi()
        await api.set(detail: try decodeDetail())
        let store = ReminderDetailStore(id: "page-date", api: api)
        await store.load()
        XCTAssertTrue(store.canPause)
        XCTAssertFalse(store.canResume)
        await store.pause()
        XCTAssertEqual(store.reminder?.state, .paused)
        XCTAssertTrue(store.canResume)
        XCTAssertFalse(store.canPause)
        await store.resume()
        XCTAssertEqual(store.reminder?.state, .armed)
        let calls = await api.calls
        XCTAssertEqual(calls, ["get", "pause", "resume"])
    }

    @MainActor
    func testATestOfAPlaceReminderIsGivenTheEventItWaitsFor() async throws {
        let api = FakeReminderApi()
        await api.set(detail: try decodeList()[0])
        let store = ReminderDetailStore(id: "office-library-book", api: api)
        await store.load()
        await store.test(notify: false)
        let tested = await api.testedWith
        XCTAssertEqual(tested.count, 1)
        XCTAssertEqual(tested[0].0, ReminderTestEvent(place: "Office", on: "enter"))
        XCTAssertFalse(tested[0].1)
        XCTAssertNotNil(store.testResult)
    }

    @MainActor
    func testADeleteMarksTheStoreSoTheScreenCanLeave() async throws {
        let api = FakeReminderApi()
        await api.set(detail: try decodeDetail())
        let store = ReminderDetailStore(id: "page-date", api: api)
        await store.load()
        await store.delete()
        XCTAssertTrue(store.isDeleted)
        await api.fail(with: PaiError.detail("busy", statusCode: 409))
        let again = ReminderDetailStore(id: "page-date", api: api)
        await again.delete()
        XCTAssertFalse(again.isDeleted)
        XCTAssertEqual(again.errorMessage, "busy")
    }
}
