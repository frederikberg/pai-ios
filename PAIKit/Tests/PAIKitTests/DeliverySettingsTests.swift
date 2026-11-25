import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private actor FakeDevicesApi: PushDevicesApiClient {
    var devices: [PushDevice]
    private(set) var patches: [(String, PushDevicePatch)] = []
    init(devices: [PushDevice]) { self.devices = devices }
    func listPushDevices() async throws -> [PushDevice] { devices }
    func patchPushDevice(id: String, _ patch: PushDevicePatch) async throws { patches.append((id, patch)) }
}

private actor FakeConnectionsApi: ConnectionsApiClient {
    private(set) var tested: [String] = []
    private(set) var loads = 0
    var failTest = false
    func listConnections() async throws -> [ServiceConnection] {
        loads += 1
        return [
            ServiceConnection(id: "anthropic", label: "Anthropic", kind: .model, testable: true),
            ServiceConnection(id: "todoist", label: "Todoist", kind: .integration, testable: true),
        ]
    }
    func testConnection(id: String) async throws -> ConnectionTestResult {
        if failTest { throw PaiError.detail("Anthropic has no key or address to test with", statusCode: 409) }
        tested.append(id)
        return ConnectionTestResult(ok: true, latencyMs: 120)
    }
    func setConnectionAddressPart(id: String, value: String?) async throws -> ServiceConnection {
        ServiceConnection(id: id, label: id, kind: .model)
    }
    func failTests() { failTest = true }
}

private actor FakeRoutesApi: ModelRoutesApiClient {
    var features: [ModelFeature]
    var refusal: PaiError?
    private(set) var puts: [(String, ModelRouteUpdate)] = []
    init(features: [ModelFeature]) { self.features = features }
    func refuse(with error: PaiError?) { refusal = error }
    func listModelFeatures() async throws -> [ModelFeature] { features }
    func putModelRoute(feature: String, _ update: ModelRouteUpdate) async throws -> ModelFeature {
        if let refusal { throw refusal }
        puts.append((feature, update))
        let old = features.first { $0.id == feature }!
        return ModelFeature(
            id: old.id, label: old.label, group: old.group, default: update.default, fallback: update.fallback,
            choices: old.choices, fallbackChoices: old.fallbackChoices)
    }
}

/// The delivery settings: this phone's pause and sleep window, the connections list, and the model routes.
final class DeliverySettingsTests: XCTestCase {
    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func client() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private func stub(_ json: String) {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    private func sentBody() throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(PaiStubURLProtocol.capturedBody)) as? [String: Any])
    }

    // MARK: Registration carries the window

    /// The window and the wake-early moment are always written: an omitted key would leave a window
    /// the person turned off still in force on the server.
    func testRegistrationAlwaysWritesTheSleepWindowAndWakeEarlyAsNullOrValue() async throws {
        stub(#"{"token":"abc","registered":true,"last_seen_at":null,"muted_channels":[]}"#)
        _ = try await client().registerDevice(token: "abc", mutedChannels: [])
        let off = try sentBody()
        XCTAssertTrue(off["sleep"] is NSNull)
        XCTAssertTrue(off["sleep_skip_until"] is NSNull)

        let choice = DeviceSleepChoice(
            window: .init(start: "22:00", end: "05:00", tz: "Europe/Berlin"), skipUntil: "2026-11-26T04:00:00+00:00")
        _ = try await client().registerDevice(token: "abc", mutedChannels: [], sleep: choice)
        let on = try sentBody()
        XCTAssertEqual(on["sleep"] as? [String: String], ["start": "22:00", "end": "05:00", "tz": "Europe/Berlin"])
        XCTAssertEqual(on["sleep_skip_until"] as? String, "2026-11-26T04:00:00+00:00")
    }

    func testTheStoreHandsTheServerTheWindowTheSleepStoreHolds() {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SleepModeStore(
            storage: SettingsInMemoryKeyValueStore(), now: { clock }, zone: { TimeZone(identifier: "Europe/Berlin")! },
            makeSalt: { "00112233445566778899aabbccddeeff" })
        XCTAssertEqual(store.deviceChoice(), .none, "sleep mode off sends nothing, which clears the server's")
        store.enable(window: .standard, pin: "1234")
        XCTAssertEqual(
            store.deviceChoice().window, .init(start: "22:00", end: "05:00", tz: "Europe/Berlin"))
        XCTAssertNil(store.deviceChoice().skipUntil)
    }

    func testUTCStringsCarryTheirOffsetAndWholeSeconds() {
        XCTAssertEqual(
            IsoTimestamp.utcString(from: IsoTimestamp.date(from: "2026-11-26T05:00:00.987+01:00")!),
            "2026-11-26T04:00:00+00:00")
    }

    // MARK: Devices

    func testADevicesPauseEndsWithNullAndStartsWithAnOffsetTime() throws {
        func sent(_ patch: PushDevicePatch) throws -> [String: Any] {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        }
        XCTAssertTrue(try sent(PushDevicePatch(pause: .resume))["paused_until"] is NSNull)
        XCTAssertEqual(
            try sent(PushDevicePatch(pause: .until("2026-11-25T23:00:00+00:00")))["paused_until"] as? String,
            "2026-11-25T23:00:00+00:00")
        XCTAssertEqual(Set(try sent(PushDevicePatch(pushEnabled: false)).keys), ["push_enabled"])
        XCTAssertTrue(try sent(PushDevicePatch()).isEmpty)
    }

    func testThePausePresetsEndWhereTheyDoAndTheMorningIsTheNextOne() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let now = IsoTimestamp.date(from: "2026-11-25T23:30:00+01:00")!
        let presets = PushPausePreset.presets(now: now, zone: berlin)
        XCTAssertEqual(presets.map(\.until).prefix(3).map { $0.timeIntervalSince(now) }, [1800, 3600, 10800])
        XCTAssertEqual(presets.last?.until, IsoTimestamp.date(from: "2026-11-26T07:00:00+01:00")!)
        let earlier = PushPausePreset.presets(now: IsoTimestamp.date(from: "2026-11-25T06:00:00+01:00")!, zone: berlin)
        XCTAssertEqual(earlier.last?.until, IsoTimestamp.date(from: "2026-11-25T07:00:00+01:00")!)
    }

    @MainActor
    func testThisPhoneIsTheRowMarkedAndPausingWritesToItsId() async throws {
        let api = FakeDevicesApi(devices: [
            PushDevice(id: "b1", kind: .browser, name: "Firefox"),
            PushDevice(id: "p1", kind: .iphone, name: "iPhone", thisDevice: true),
        ])
        let store = PushDevicesStore(api: api)
        await store.load()
        XCTAssertEqual(store.thisDevice?.id, "p1")
        XCTAssertEqual(store.otherDevices.map(\.id), ["b1"])

        await store.pause(try XCTUnwrap(store.thisDevice), until: Date(timeIntervalSince1970: 1_800_000_000))
        await store.setEnabled(false, on: try XCTUnwrap(store.thisDevice))
        let patches = await api.patches
        XCTAssertEqual(patches.map(\.0), ["p1", "p1"])
        XCTAssertEqual(patches[0].1.pause, .until("2027-01-15T08:00:00+00:00"))
        XCTAssertEqual(patches[1].1.pushEnabled, false)
    }

    func testTheDeviceListDecodesBothKindsAndAPauseInThePastIsNoPause() throws {
        let json = """
            {"devices": [
              {"id": "p1", "kind": "iphone", "name": "iPhone", "this_device": true, "push_enabled": true,
               "paused_until": "2026-11-25T10:00:00+00:00",
               "sleep": {"start": "22:00", "end": "05:00", "tz": "Europe/Berlin", "active": false, "skip_until": null},
               "sleep_skip_until": null, "muted_channels": ["alarm"], "last_success_at": null},
              {"id": "b1", "kind": "browser", "name": "Firefox", "this_device": false, "push_enabled": true,
               "paused_until": null, "sleep": null, "sleep_skip_until": null, "muted_channels": [],
               "last_success_at": "2026-11-25T09:00:00+00:00"}]}
            """
        struct Wrapper: Decodable { let devices: [PushDevice] }
        let devices = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).devices
        XCTAssertEqual(devices[0].sleep?.tz, "Europe/Berlin")
        XCTAssertEqual(devices[1].kind, .browser)
        let later = IsoTimestamp.date(from: "2026-11-25T12:00:00+00:00")!
        XCTAssertNil(devices[0].pausedUntilDate(after: later))
        XCTAssertNotNil(devices[0].pausedUntilDate(after: IsoTimestamp.date(from: "2026-11-25T09:00:00+00:00")!))
    }

    func testNoPushReachesAnyDeviceOnlyWhenEveryPushSwitchTheyHaveIsOff() {
        XCTAssertTrue(NotificationMatrix.reachesNoDevice(person: ["push_agent_messages": .bool(false)]))
        XCTAssertTrue(
            NotificationMatrix.reachesNoDevice(person: ["push_agent_messages": .bool(false), "push_alerts": .bool(false)]))
        XCTAssertFalse(
            NotificationMatrix.reachesNoDevice(person: ["push_agent_messages": .bool(false), "push_alerts": .bool(true)]))
        XCTAssertFalse(NotificationMatrix.reachesNoDevice(person: [:]), "nothing read yet is not an answer")
    }

    // MARK: Connections

    func testAConnectionDecodesWithoutAKeyOfOurs() throws {
        let json = """
            {"id": "mailverdict", "label": "MailVerdict", "kind": "integration", "base_url": null,
             "base_url_param": null, "credential": null, "extra": [], "status": "ok", "status_detail": null,
             "note": "Each device signs in itself", "testable": false, "used_by": [], "spend": null}
            """
        let connection = try JSONDecoder().decode(ServiceConnection.self, from: Data(json.utf8))
        XCTAssertNil(connection.credential)
        XCTAssertEqual(connection.status, .ok)
        let later = try JSONDecoder().decode(
            ServiceConnection.self,
            from: Data(
                #"{"id":"x","label":"X","kind":"widget","status":"asleep","credential":{"secret":"x_key","set":true,"updated_at":null,"source":"vault"}}"#
                    .utf8))
        XCTAssertEqual(later.kind, .unrecognized("widget"))
        XCTAssertEqual(later.status, .unrecognized("asleep"))
        XCTAssertEqual(later.credential?.source, .unrecognized("vault"))
    }

    @MainActor
    func testATestKeepsItsAnswerAndRereadsTheListAndARefusalIsSaidAsItIs() async throws {
        let api = FakeConnectionsApi()
        let store = ConnectionsStore(api: api)
        await store.load()
        let anthropic = try XCTUnwrap(store.connections?.first)
        await store.test(anthropic)
        XCTAssertEqual(store.tests["anthropic"]?.ok, true)
        let loads = await api.loads
        XCTAssertEqual(loads, 2, "the status can change after a test")

        await api.failTests()
        await store.test(anthropic)
        XCTAssertNil(store.tests["anthropic"])
        XCTAssertEqual(store.testError["anthropic"], "Anthropic has no key or address to test with")
        XCTAssertEqual(store.connections(ofKinds: [.integration]).map(\.id), ["todoist"])
    }

    func testTheAddressPartIsWrittenAsNullToGoBackToTheDeployments() async throws {
        stub(#"{"connection":{"id":"infomaniak","label":"Infomaniak","kind":"model","status":"ok"}}"#)
        _ = try await client().setConnectionAddressPart(id: "infomaniak", value: nil)
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "PATCH")
        XCTAssertTrue(try sentBody()["base_url_param"] is NSNull)
        _ = try await client().setConnectionAddressPart(id: "infomaniak", value: "1234")
        XCTAssertEqual(try sentBody()["base_url_param"] as? String, "1234")
    }

    // MARK: Model routes

    private func feature() -> ModelFeature {
        ModelFeature(
            id: "turn_summary", label: "Turn summaries", group: "memory",
            default: ModelStep(provider: "anthropic", model: "haiku", effort: "medium"),
            fallback: ModelStep(provider: "infomaniak", model: "gemma", effort: nil),
            chainNow: [
                ModelChainStep(provider: "anthropic", model: "haiku", effort: "medium", skippedReason: "no key"),
                ModelChainStep(provider: "infomaniak", model: "gemma", effort: nil, skippedReason: nil),
            ],
            choices: [
                "anthropic": ["haiku": ["low", "medium"], "opus": ["high"]],
                "infomaniak": ["gemma": [nil], "qwen": [nil]],
            ],
            fallbackChoices: ["infomaniak": ["gemma": [nil], "qwen": [nil]]])
    }

    func testAFeatureDecodesNullEffortsAndNamesWhatACallWouldDoNow() throws {
        let json = """
            {"id": "ultrafast", "label": "Ultra-fast sessions", "group": "sessions", "editable": true,
             "default": {"provider": "anthropic", "model": "sonnet", "effort": "low"},
             "fallback": {"provider": "infomaniak", "model": "gemma", "effort": null},
             "fallback_allowed": true,
             "chain_now": [{"provider": "anthropic", "model": "sonnet", "effort": "low", "skipped_reason": "no key"},
                           {"provider": "infomaniak", "model": "gemma", "effort": null, "skipped_reason": null}],
             "choices": {"anthropic": {"sonnet": ["low", "high"]}, "infomaniak": {"gemma": [null]}},
             "fallback_choices": {"infomaniak": {"gemma": [null]}}}
            """
        let decoded = try JSONDecoder().decode(ModelFeature.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.choices["infomaniak"]?["gemma"] ?? [], [nil])
        XCTAssertEqual(decoded.nowText, "Now: Anthropic sonnet skipped (no key), then Infomaniak gemma")
    }

    func testMovingToAnotherModelKeepsAnEffortItAcceptsAndOtherwiseTakesItsFirst() {
        var draft = ModelRouteDraft(feature: feature())
        draft.chooseModel("opus", forFallback: false)
        XCTAssertEqual(draft.defaultStep, ModelStep(provider: "anthropic", model: "opus", effort: "high"))
        draft.chooseModel("haiku", forFallback: false)
        XCTAssertEqual(draft.defaultStep.effort, "low", "high is not a haiku effort")
        draft.chooseEffort("medium", forFallback: false)
        draft.chooseProvider("infomaniak", forFallback: false)
        XCTAssertEqual(draft.defaultStep, ModelStep(provider: "infomaniak", model: "gemma", effort: nil))
    }

    func testAFallbackIsAddedFromTheFirstChoiceAndRemovedWithNull() throws {
        var draft = ModelRouteDraft(feature: feature())
        draft.setFallback(enabled: false)
        XCTAssertNil(draft.fallbackStep)
        let removed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.update)) as? [String: Any]
        XCTAssertTrue(removed?["fallback"] is NSNull, "an omitted key would leave the stored fallback in force")
        draft.setFallback(enabled: true)
        XCTAssertEqual(draft.fallbackStep, ModelStep(provider: "infomaniak", model: "gemma", effort: nil))
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.update)) as? [String: Any]
        let fallback = written?["fallback"] as? [String: Any]
        XCTAssertTrue(fallback?["effort"] is NSNull)
    }

    func testAFeatureWithNoFallbackSlotOffersNone() {
        let single = ModelFeature(
            id: "fast", label: "Fast", group: "sessions", default: ModelStep(provider: "claude", model: "sonnet"),
            fallbackAllowed: false, choices: ["claude": ["sonnet": ["low"]]], fallbackChoices: nil)
        var draft = ModelRouteDraft(feature: single)
        XCTAssertFalse(draft.offersFallback)
        draft.setFallback(enabled: true)
        XCTAssertNil(draft.fallbackStep)
    }

    @MainActor
    func testASavedRouteReplacesItsRowAndARefusalKeepsTheOldOneWithTheServersReason() async throws {
        let api = FakeRoutesApi(features: [feature()])
        let store = ModelRoutesStore(api: api)
        await store.load()
        var draft = ModelRouteDraft(feature: try XCTUnwrap(store.features?.first))
        draft.chooseModel("opus", forFallback: false)
        let saved = await store.save(try XCTUnwrap(store.features?.first), draft.update)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.features?.first?.default.model, "opus")

        await api.refuse(with: .detail("Anthropic has no key", statusCode: 409))
        draft.chooseModel("haiku", forFallback: false)
        let refused = await store.save(try XCTUnwrap(store.features?.first), draft.update)
        XCTAssertFalse(refused)
        XCTAssertEqual(store.features?.first?.default.model, "opus")
        XCTAssertEqual(store.saveError, "Anthropic has no key")
    }
}
