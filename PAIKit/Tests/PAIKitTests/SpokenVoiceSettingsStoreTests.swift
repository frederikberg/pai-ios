import XCTest

@testable import PAIKit

/// The draft-and-save half of the spoken voice settings: what counts as dirty, what a typed
/// speed has to be before Save is offered, and what an empty field sends.
///
/// Neither the class nor any test method is `@MainActor`, even though the store correctly is —
/// see `SettingsSmtpSettingsStoreTests` for the Linux XCTest discovery crash that forbids it.
/// Every store access is `await`ed instead.
final class SpokenVoiceSettingsStoreTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    private static func makeStore() throws -> SpokenVoiceSettingsStore {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let client = PaiApiClient(
            requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        return SpokenVoiceSettingsStore(apiClient: client)
    }

    private func stubSettings(speed: Double = 1.0) {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                """
                {"call_voice_id":null,"call_speed":\(speed),
                 "stt_keyterms":[],"stt_language":null,"stt_no_verbatim":false,
                 "debug_recordings_enabled":true,
                 "updated_at":"2026-09-20T12:00:00.123456+00:00"}
                """.utf8)
        )
    }

    private func loaded(
        callVoiceId: String? = nil, callSpeed: Double = 1.0, sttKeyterms: [String] = [],
        sttBatchPauseS: Int? = nil
    ) -> SpokenVoiceSettings {
        SpokenVoiceSettings(
            callVoiceId: callVoiceId, callSpeed: callSpeed, sttKeyterms: sttKeyterms, sttLanguage: nil,
            sttNoVerbatim: false, sttBatchPauseS: sttBatchPauseS, debugRecordingsEnabled: true,
            updatedAt: "2026-09-20T12:00:00Z")
    }

    /// An unset field and an empty text field are the same thing to a person, and have to be the
    /// same thing here — otherwise opening the screen and saving writes empty strings over
    /// nulls.
    func testAnUnsetFieldRoundTripsAsEmptyAndBackToNull() {
        let draft = SpokenVoiceSettingsDraft(loaded: loaded())

        XCTAssertEqual(draft.callVoiceId, "")

        let update = draft.asUpdate()
        XCTAssertNil(update?.callVoiceId)
    }

    /// The speed is a string in the draft so a half-typed number is a state the field can be in.
    /// It must not be a state Save accepts: a value silently becoming 1.0 is exactly the outcome
    /// that reads as the setting not working.
    func testAHalfTypedOrOutOfRangeSpeedCannotBeSaved() {
        for bad in ["", "-", "abc", "0.1", "1.3", "9"] {
            var draft = SpokenVoiceSettingsDraft(loaded: loaded())
            draft.callSpeed = bad
            XCTAssertNil(draft.speed, "expected \(bad.debugDescription) to be unusable")
            XCTAssertNil(draft.asUpdate(), "expected no update for \(bad.debugDescription)")
        }
    }

    func testTheBoundsThemselvesAreUsable() {
        for good in [callSpeedRange.lowerBound, 1.0, callSpeedRange.upperBound] {
            var draft = SpokenVoiceSettingsDraft(loaded: loaded())
            draft.callSpeed = String(good)
            XCTAssertEqual(draft.speed, good)
        }
    }

    /// The stored speed has to come back as something `Double(_:)` reads again — a locale that
    /// wrote a comma separator would round-trip into a save that cannot parse its own field.
    func testAStoredSpeedRoundTripsThroughTheTextField() {
        let draft = SpokenVoiceSettingsDraft(loaded: loaded(callSpeed: 1.15))

        XCTAssertEqual(draft.callSpeed, "1.15")
        XCTAssertEqual(draft.speed, 1.15)
    }

    /// Clearing a field has to reach the backend as `null`: an omitted key means "leave as-is"
    /// there, so a cleared voice that was simply left out of the body would never clear.
    func testAClearedFieldIsSentAsNullNotOmitted() throws {
        var draft = SpokenVoiceSettingsDraft(loaded: loaded(callVoiceId: "voice-1"))
        draft.callVoiceId = ""
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(draft.asUpdate())))
        let object = try XCTUnwrap(body as? [String: Any])
        XCTAssertTrue(object.keys.contains("call_voice_id"))
        XCTAssertTrue(object["call_voice_id"] is NSNull)
    }

    /// Key terms travel as a list, and one ElevenLabs would refuse blocks Save rather than
    /// failing the whole PUT server-side.
    func testKeyTermsAreSplitAndAnUnacceptableOneBlocksSave() {
        var draft = SpokenVoiceSettingsDraft(loaded: loaded(sttKeyterms: ["Computer"]))
        XCTAssertEqual(draft.sttKeyterms, "Computer")
        draft.sttKeyterms = " Computer ,,PAI "
        XCTAssertEqual(draft.asUpdate()?.sttKeyterms, ["Computer", "PAI"])

        draft.sttKeyterms = "Computer, Supercalifragilistic word"
        XCTAssertNotNil(draft.keytermProblem)
        XCTAssertNil(draft.asUpdate())
    }

    /// Off has to reach the backend as `null`: an omitted key leaves the stored seconds in force,
    /// so a switch that turned off locally would silently stay on.
    func testSwitchingTheBatchPauseOffSendsNullAndOnSendsTheSeconds() throws {
        var draft = SpokenVoiceSettingsDraft(loaded: loaded(sttBatchPauseS: 30))
        XCTAssertTrue(draft.sttBatchPauseEnabled)
        XCTAssertEqual(draft.sttBatchPauseS, "30")
        XCTAssertEqual(draft.asUpdate()?.sttBatchPauseS, 30)

        draft.sttBatchPauseEnabled = false
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(draft.asUpdate())))
        let object = try XCTUnwrap(body as? [String: Any])
        XCTAssertTrue(object.keys.contains("stt_batch_pause_s"))
        XCTAssertTrue(object["stt_batch_pause_s"] is NSNull)
    }

    /// While the setting is off the seconds field is not shown, so whatever it holds must not
    /// block Save; while on, a value outside the backend's 5...120 must.
    func testOnlyAnEnabledBatchPauseHasToBeInRange() {
        var draft = SpokenVoiceSettingsDraft(loaded: loaded(sttBatchPauseS: nil))
        XCTAssertFalse(draft.sttBatchPauseEnabled)
        draft.sttBatchPauseS = "abc"
        XCTAssertNotNil(draft.asUpdate())

        draft.sttBatchPauseEnabled = true
        for bad in ["", "4", "121", "7.5", "abc"] {
            draft.sttBatchPauseS = bad
            XCTAssertNil(draft.asUpdate(), "expected no update for \(bad.debugDescription)")
        }
        for good in ["5", "120", " 15 "] {
            draft.sttBatchPauseS = good
            XCTAssertNotNil(draft.asUpdate(), "expected an update for \(good.debugDescription)")
        }
    }

    /// A backend that predates the setting leaves the key out; that must decode (as off), not
    /// fail the whole screen's load.
    func testSettingsFromABackendWithoutTheBatchPauseKeyStillDecode() async throws {
        stubSettings()
        let store = try await Self.makeStore()

        await store.load()

        let loadError = await store.loadError
        let pause = await store.loaded?.sttBatchPauseS
        let enabled = await store.draft?.sttBatchPauseEnabled
        XCTAssertNil(loadError)
        XCTAssertNil(pause)
        XCTAssertEqual(enabled, false)
    }

    func testBeforeLoadNothingIsDirtyOrSaveable() async throws {
        let store = try await Self.makeStore()

        let isDirty = await store.isDirty
        let canSave = await store.canSave
        XCTAssertFalse(isDirty)
        XCTAssertFalse(canSave)
    }

    func testLoadingLeavesTheDraftCleanAndSaveUnoffered() async throws {
        stubSettings()
        let store = try await Self.makeStore()

        await store.load()

        let loadedValue = await store.loaded
        let isDirty = await store.isDirty
        let canSave = await store.canSave
        XCTAssertNotNil(loadedValue)
        XCTAssertFalse(isDirty)
        XCTAssertFalse(canSave)
    }

    func testEditingAFieldOffersSaveAndAnUnusableSpeedWithdrawsIt() async throws {
        stubSettings()
        let store = try await Self.makeStore()
        await store.load()

        await MainActor.run { store.draft?.callVoiceId = "marin" }
        var isDirty = await store.isDirty
        var canSave = await store.canSave
        XCTAssertTrue(isDirty)
        XCTAssertTrue(canSave)

        await MainActor.run { store.draft?.callSpeed = "not a number" }
        isDirty = await store.isDirty
        canSave = await store.canSave
        XCTAssertTrue(isDirty)
        XCTAssertFalse(canSave, "a dirty draft with an unusable speed must not be savable")
    }

    // MARK: - Computer

    private func choices() throws -> ComputerChoices {
        let voice = try JSONDecoder().decode(
            SpokenVoiceSettings.self, from: Data(PaiFixtures.spokenVoiceSettings.utf8))
        return try XCTUnwrap(voice.computerChoices)
    }

    /// Unset Computer fields are "the default" and have to go out as `null` — an omitted key would
    /// leave a stored choice in force, so a choice reset to the default would never reset.
    func testAnUnsetComputerChoiceIsSentAsNullAndASetOneAsItself() throws {
        var draft = SpokenVoiceSettingsDraft(loaded: loaded())
        let unset = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(draft.asUpdate())))
        let object = try XCTUnwrap(unset as? [String: Any])
        for key in [
            "computer_claude_model", "computer_claude_effort", "computer_turn_preset",
            "computer_turn_tunables",
        ] {
            XCTAssertTrue(object.keys.contains(key), key)
            XCTAssertTrue(object[key] is NSNull, key)
        }

        draft.computerTurnPreset = "explicit"
        XCTAssertEqual(draft.asUpdate()?.computerTurnPreset, "explicit")
    }

    /// The backend refuses a model and effort that do not go together, so a model change that
    /// strands the effort has to take the effort back rather than offer a Save that 400s.
    func testChoosingAModelThatCannotTakeTheEffortResetsIt() throws {
        let sonnetLimited = ComputerChoices(
            claudeModels: ["big": ["low", "high"], "small": ["low"]], turnPresets: [:],
            defaults: .init(
                computerClaudeModel: "big", computerClaudeEffort: "low",
                computerTurnPreset: "normal"))
        var draft = SpokenVoiceSettingsDraft(loaded: loaded())
        draft.computerClaudeEffort = "high"
        XCTAssertTrue(draft.isClaudeChoiceValid(sonnetLimited))

        draft.chooseModel("small", choices: sonnetLimited)
        XCTAssertEqual(draft.computerClaudeModel, "small")
        XCTAssertEqual(draft.computerClaudeEffort, "")

        draft.computerClaudeEffort = "high"
        XCTAssertFalse(draft.isClaudeChoiceValid(sonnetLimited))
    }

    func testTunablesRoundTripAndOnlyAJSONObjectCanBeSaved() throws {
        var draft = SpokenVoiceSettingsDraft(loaded: loaded())
        XCTAssertEqual(draft.computerTurnTunables, "")
        XCTAssertNotNil(draft.asUpdate())

        draft.computerTurnTunables = #"{"end_wait_s": null, "interrupt_min_words": 3, "turn_cue": false}"#
        XCTAssertEqual(
            draft.asUpdate()?.computerTurnTunables,
            ["end_wait_s": .never, "interrupt_min_words": .number(3), "turn_cue": .flag(false)])

        let reread = SpokenVoiceSettingsDraft(
            loaded: SpokenVoiceSettings(
                computerTurnTunables: ["end_wait_s": .number(2)], callVoiceId: nil, callSpeed: 1, sttKeyterms: [],
                sttLanguage: nil,
                sttNoVerbatim: false, sttBatchPauseS: nil, debugRecordingsEnabled: true, updatedAt: ""))
        XCTAssertEqual(reread.asUpdate()?.computerTurnTunables, ["end_wait_s": .number(2)])

        for bad in ["{", "[1]", "3", "{\"end_wait_s\": \"2\"}"] {
            draft.computerTurnTunables = bad
            XCTAssertNil(draft.asUpdate(), "expected no update for \(bad.debugDescription)")
        }
        draft.computerTurnTunables = "{}"
        XCTAssertNil(draft.asUpdate()?.computerTurnTunables)
        XCTAssertNotNil(draft.asUpdate())
    }

    func testPresetSummaryReadsTheBackendsNumbers() throws {
        let choices = try choices()
        XCTAssertTrue(choices.summary(ofPreset: "patient").contains("3"))
        XCTAssertTrue(choices.summary(ofPreset: "").contains("1.2"), "empty means the default preset")
        XCTAssertTrue(choices.summary(ofPreset: "explicit").contains("computer start"))
    }

    /// A PUT carries exactly the fields the backend still has: it refuses a key it no longer
    /// knows, so one leftover from the OpenAI engine would fail every save.
    func testTheUpdateCarriesNoFieldTheBackendRemoved() throws {
        let draft = SpokenVoiceSettingsDraft(loaded: loaded())
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(draft.asUpdate())))
        let keys = try XCTUnwrap(body as? [String: Any]).keys
        for removed in [
            "computer_engine", "computer_voice", "computer_delivery", "computer_speed", "computer_credit_cap",
            "playback_fallback_voice", "playback_fallback_budget_cents",
        ] {
            XCTAssertFalse(keys.contains(removed), removed)
        }
    }

    /// The new payload: no engine list, no engine default, no credit cap, no Computer voice.
    func testTheSettingsPayloadWithoutTheRemovedKeysDecodes() throws {
        let json = """
            {"computer_claude_model": null, "computer_claude_effort": "low",
             "computer_turn_preset": "normal", "computer_turn_tunables": null,
             "computer_choices": {"claude_models": {"m": ["low"]},
               "turn_presets": {"normal": {"end_wait_s": 1.2}}, "tunable_bounds": {},
               "defaults": {"computer_claude_model": "m", "computer_claude_effort": "low",
                            "computer_turn_preset": "normal"}},
             "call_voice_id": null, "call_speed": 1.0, "stt_keyterms": [], "stt_language": null,
             "stt_no_verbatim": false, "stt_batch_pause_s": null, "debug_recordings_enabled": false,
             "updated_at": "2026-11-23T12:00:00+00:00"}
            """
        let settings = try JSONDecoder().decode(SpokenVoiceSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.computerChoices?.modelIds, ["m"])
        XCTAssertEqual(settings.computerClaudeEffort, "low")
    }

    /// A payload from before the engine went away still decodes: the extra keys are ignored.
    func testAnOlderSettingsPayloadStillDecodes() throws {
        let voice = try JSONDecoder().decode(
            SpokenVoiceSettings.self,
            from: Data(
                """
                {"computer_engine": "openai_realtime", "computer_voice": "cedar", "computer_speed": 1.2,
                 "computer_delivery": null, "computer_credit_cap": 100,
                 "computer_choices": {"engines": ["openai_realtime", "claude"], "claude_models": {},
                   "turn_presets": {}, "tunable_bounds": {},
                   "defaults": {"computer_engine": "claude", "computer_claude_model": "m",
                                "computer_claude_effort": "low", "computer_turn_preset": "normal",
                                "computer_credit_cap": 5}},
                 "call_voice_id": null, "call_speed": 1.0, "stt_keyterms": [], "stt_language": null,
                 "stt_no_verbatim": false, "debug_recordings_enabled": false, "updated_at": ""}
                """.utf8))
        XCTAssertEqual(voice.computerChoices?.defaults.computerTurnPreset, "normal")
    }
}
