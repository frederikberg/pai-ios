import XCTest

@testable import PAIKit

/// A server that holds a registry document and applies writes the way the real one does: a `null`
/// on a key that is not nullable puts the default back, and a key the schema does not list is
/// refused with the key and the rule.
actor FakeSettingsRegistryApi: SettingsRegistryApiClient {
    private var response: SettingsResponse
    private(set) var personPatches: [[String: SettingValue]] = []
    private(set) var instancePatches: [[String: SettingValue]] = []
    private var writeError: Error?
    private(set) var loads = 0

    init(response: SettingsResponse) { self.response = response }

    func failWrites(with error: Error?) { writeError = error }

    func getSettings() async throws -> SettingsResponse {
        loads += 1
        return response
    }

    func patchPersonSettings(_ patch: [String: SettingValue]) async throws -> [String: SettingValue] {
        if let writeError { throw writeError }
        personPatches.append(patch)
        let next = SettingsRegistryStore.applied(patch, to: response.person, schema: response.schema)
        response = SettingsResponse(schema: response.schema, person: next, instance: response.instance)
        return next
    }

    func patchInstanceSettings(_ patch: [String: SettingValue]) async throws -> [String: SettingValue] {
        if let writeError { throw writeError }
        instancePatches.append(patch)
        let next = SettingsRegistryStore.applied(patch, to: response.instance ?? [:], schema: response.schema)
        response = SettingsResponse(schema: response.schema, person: response.person, instance: next)
        return next
    }
}

/// The registry's wire shape, the rows its kinds draw, and what the store does with a write.
final class SettingsRegistryTests: XCTestCase {
    private func owner() throws -> SettingsResponse {
        try JSONDecoder().decode(SettingsResponse.self, from: Data(PaiFixtures.settingsRegistryOwner.utf8))
    }

    private func guest() throws -> SettingsResponse {
        try JSONDecoder().decode(SettingsResponse.self, from: Data(PaiFixtures.settingsRegistryGuest.utf8))
    }

    @MainActor
    private func store(_ response: SettingsResponse, cache: SettingsInMemoryKeyValueStore = .init())
        -> (SettingsRegistryStore, FakeSettingsRegistryApi)
    {
        let api = FakeSettingsRegistryApi(response: response)
        return (SettingsRegistryStore(api: api, cache: cache), api)
    }

    // MARK: Wire

    func testTheOwnersDocumentDecodesWithEveryScopeAndKind() throws {
        let response = try owner()
        XCTAssertEqual(response.schema["recording_mode"]?.kind, .enum)
        XCTAssertEqual(response.schema["recording_mode"]?.choices, ["live", "batch"])
        XCTAssertEqual(response.schema["stt_batch_pause_s"]?.nullable, true)
        XCTAssertEqual(response.schema["stt_batch_pause_s"]?.min, 5)
        XCTAssertEqual(response.schema["stt_keyterms"]?.maxItems, 50)
        XCTAssertNotNil(response.schema["stt_keyterms"]?.warning)
        XCTAssertEqual(response.schema["default_voice_id"]?.scope, .instance)
        XCTAssertEqual(response.schema["call_speed"]?.ownerOnly, true)
        XCTAssertEqual(response.person["playback_speed"]?.doubleValue, 1)
        XCTAssertEqual(response.instance?["debug_recordings_enabled"], .bool(true))
    }

    func testAGuestsDocumentHasNoInstanceAndNoOwnerKeys() throws {
        let response = try guest()
        XCTAssertNil(response.instance)
        XCTAssertNil(response.schema["call_speed"])
        XCTAssertNil(response.person["computer_turn_preset"])
        XCTAssertNotNil(response.schema["playback_speed"])
    }

    func testAKindThisBuildDoesNotKnowDecodesAndIsNotDrawn() throws {
        let json = """
            {"schema": {"later": {"scope": "person", "kind": "colour", "default": null, "nullable": false,
              "owner_only": false, "ui": true, "label": "Later", "help": "", "warning": null}},
             "person": {"later": "red"}, "instance": null}
            """
        let response = try JSONDecoder().decode(SettingsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.schema["later"]?.kind, .unrecognized("colour"))
        XCTAssertNil(SettingField(key: "later", schema: response.schema["later"]!, value: .string("red")))
    }

    func testANumberWithAFractionWhereAWholeOneIsMeantStillDecodes() throws {
        let json = """
            {"scope": "person", "kind": "int", "default": 5, "min": 2.0, "max": 60, "step": 1, "max_len": 8.4,
             "nullable": false, "owner_only": false, "ui": true, "label": "x", "help": "", "warning": null}
            """
        let schema = try JSONDecoder().decode(SettingSchema.self, from: Data(json.utf8))
        XCTAssertEqual(schema.maxLen, 8)
        XCTAssertEqual(schema.defaultValue.intValue, 5)
    }

    // MARK: Rows

    func testEveryKindIsDrawnByItsOwnControl() throws {
        let response = try owner()
        func control(_ key: String) -> SettingField.Control? {
            response.schema[key].flatMap { SettingField(key: key, schema: $0, value: response.person[key] ?? .null) }?
                .control
        }
        XCTAssertEqual(control("stt_no_verbatim"), .toggle)
        XCTAssertEqual(control("recording_mode"), .choice(["live", "batch"]))
        XCTAssertEqual(control("playback_speed"), .number)
        XCTAssertEqual(control("stt_batch_pause_s"), .optionalNumber)
        XCTAssertEqual(control("stt_language"), .text)
        XCTAssertEqual(control("location_sign_in_id"), .text)
        XCTAssertEqual(control("stt_keyterms"), .list)
        XCTAssertEqual(control("computer_turn_tunables"), .json)
    }

    func testSwitchesAndChoicesSaveOnChangeTheRestOnRequest() throws {
        let response = try owner()
        func saves(_ key: String) -> Bool? {
            response.schema[key].flatMap { SettingField(key: key, schema: $0, value: .null) }?.savesOnChange
        }
        XCTAssertEqual(saves("stt_no_verbatim"), true)
        XCTAssertEqual(saves("recording_mode"), true)
        XCTAssertEqual(saves("playback_speed"), false)
        XCTAssertEqual(saves("stt_keyterms"), false)
    }

    func testTextBecomesTheValueItsKeyHolds() throws {
        let response = try owner()
        func field(_ key: String) -> SettingField {
            SettingField(key: key, schema: response.schema[key]!, value: response.person[key] ?? .null)!
        }
        XCTAssertEqual(try field("playback_speed").parse(" 1,25 ").get(), .double(1.25))
        XCTAssertEqual(try field("alarm_ring_interval_s").parse("10").get(), .whole(10))
        XCTAssertEqual(
            field("alarm_ring_interval_s").parse("2.5"), .failure(SettingFieldProblem(message: "Enter a whole number")))
        XCTAssertEqual(field("playback_speed").parse("fast"), .failure(SettingFieldProblem(message: "Enter a number")))
        XCTAssertEqual(try field("stt_language").parse("  ").get(), .null, "empty text is null")
        XCTAssertEqual(try field("stt_language").parse(" de ").get(), .string("de"))
        XCTAssertEqual(
            try field("stt_keyterms").parse("Aachen, PAI\n\nElastic").get(),
            .array([.string("Aachen"), .string("PAI"), .string("Elastic")]))
        XCTAssertEqual(try field("computer_turn_tunables").parse("").get(), .null)
        XCTAssertEqual(try field("computer_turn_tunables").parse("{}").get(), .null)
        XCTAssertEqual(
            try field("computer_turn_tunables").parse(#"{"end_wait_s": 2}"#).get(),
            .object(["end_wait_s": .number(2)]))
        for bad in ["{", "[1]", "3"] {
            if case .success = field("computer_turn_tunables").parse(bad) { XCTFail("\(bad) is no JSON object") }
        }
    }

    func testTheStoredTextRoundTripsThroughParse() throws {
        let response = try owner()
        for (key, value) in [
            ("playback_speed", SettingValue.double(1.25)), ("alarm_ring_interval_s", .whole(7)),
            ("stt_keyterms", .array([.string("a"), .string("b")])),
            ("computer_turn_tunables", .object(["end_wait_s": .number(2), "turn_cue": .bool(false)])),
        ] {
            let field = SettingField(key: key, schema: response.schema[key]!, value: value)!
            XCTAssertEqual(try field.parse(field.storedText).get(), value, key)
        }
    }

    // MARK: Store

    @MainActor
    func testTheStoreHidesWhatTheCallerMayNotSeeAndWhatTheServerKeepsOffScreens() async throws {
        let (owned, _) = store(try owner())
        await owned.load()
        XCTAssertNotNil(owned.field("call_speed"))
        XCTAssertNotNil(owned.field("default_voice_id"))
        XCTAssertNil(owned.field("call_interrupt"), "ui: false")
        XCTAssertNil(owned.field("no_such_key"))

        let (guested, _) = store(try guest())
        await guested.load()
        XCTAssertNil(guested.field("call_speed"))
        XCTAssertNil(guested.field("default_voice_id"))
        XCTAssertNotNil(guested.field("stt_language"))
    }

    @MainActor
    func testAChangeShowsAtOnceAndTheServersAnswerReplacesIt() async throws {
        let (store, api) = store(try owner())
        await store.load()
        XCTAssertEqual(store.recordingMode, .live)

        let saved = await store.updatePerson(["recording_mode": .string("batch")])
        XCTAssertTrue(saved)
        XCTAssertEqual(store.recordingMode, .batch)
        let patches = await api.personPatches
        XCTAssertEqual(patches.count, 1)
    }

    @MainActor
    func testARefusedWritePutsTheOldValuesBack() async throws {
        let (store, api) = store(try owner())
        await store.load()
        await api.failWrites(with: PaiError.detail("must be between 0.5 and 2", statusCode: 422))

        let saved = await store.updatePerson(["playback_speed": .double(9)])
        XCTAssertFalse(saved)
        XCTAssertEqual(store.playbackSpeed, 1)
        XCTAssertEqual(store.errorMessage, "must be between 0.5 and 2")
    }

    @MainActor
    func testAFieldSavedOnRequestKeepsTheTypedTextWhenRefused() async throws {
        let (store, api) = store(try owner())
        await store.load()
        await api.failWrites(with: PaiError.detail("nope", statusCode: 422))
        let before = store.field("playback_speed")?.value
        // Not optimistic: nothing is shown until the server agrees, so a refusal changes nothing
        // and the screen's own draft is what stays.
        let saved = await store.updatePerson(["playback_speed": .double(9)], optimistic: false)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.field("playback_speed")?.value, before)
    }

    @MainActor
    func testNullOnAKeyThatIsNotNullableShowsItsDefaultAtOnce() async throws {
        let (store, api) = store(try owner())
        await store.load()
        await store.updatePerson(["playback_speed": .double(1.5)])
        XCTAssertEqual(store.playbackSpeed, 1.5)
        await api.failWrites(with: PaiError.transport("offline"))
        _ = await store.updatePerson(["playback_speed": .null])
        XCTAssertEqual(store.playbackSpeed, 1.5, "the refused reset is put back")
        await api.failWrites(with: nil)
        await store.updatePerson(["playback_speed": .null])
        XCTAssertEqual(store.playbackSpeed, 1, "the registry default, never one of the client's")
    }

    @MainActor
    func testAKeyIsWrittenToTheScopeItsSchemaNames() async throws {
        let (store, api) = store(try owner())
        await store.load()
        await store.update("default_voice_id", to: .string("voice-1"))
        await store.update("stt_no_verbatim", to: .bool(true))
        let instance = await api.instancePatches
        let person = await api.personPatches
        XCTAssertEqual(instance, [["default_voice_id": .string("voice-1")]])
        XCTAssertEqual(person, [["stt_no_verbatim": .bool(true)]])
        XCTAssertEqual(store.instance?["default_voice_id"]?.stringValue, "voice-1")
        let unknown = await store.update("no_such_key", to: .bool(true))
        XCTAssertFalse(unknown)
    }

    @MainActor
    func testTheLastPersonValuesAreKeptForTheNextLaunch() async throws {
        let cache = SettingsInMemoryKeyValueStore()
        let (first, _) = store(try owner(), cache: cache)
        await first.load()
        await first.updatePerson(["recording_mode": .string("batch")])
        let (next, _) = store(try owner(), cache: cache)
        XCTAssertEqual(next.recordingMode, .batch, "before the network answers")
        XCTAssertFalse(next.isLoaded)
    }

    @MainActor
    func testTheRecordingModeThePressStartsComesFromTheSettings() async throws {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let settings = SettingsStore(
            apiClient: PaiApiClient(requestFactory: factory), storage: SettingsInMemoryKeyValueStore())
        XCTAssertEqual(settings.defaultRecordingMode, .live, "until the person's settings have been read")
        XCTAssertEqual(settings.alternateRecordingMode, .batch)
    }
}
