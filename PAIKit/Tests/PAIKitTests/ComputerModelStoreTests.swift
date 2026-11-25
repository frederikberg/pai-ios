import XCTest

@testable import PAIKit

private actor FakeComputerModelApi: ComputerModelApiClient {
    private var settings: SpokenVoiceSettings
    private(set) var updates: [ComputerModelUpdate] = []

    init(settings: SpokenVoiceSettings) { self.settings = settings }

    func getVoiceSettings() async throws -> SpokenVoiceSettings { settings }

    func updateComputerModel(_ update: ComputerModelUpdate) async throws -> SpokenVoiceSettings {
        updates.append(update)
        let current = settings
        settings = SpokenVoiceSettings(
            computerClaudeModel: update.model, computerClaudeEffort: update.effort,
            computerTurnPreset: current.computerTurnPreset, computerTurnTunables: current.computerTurnTunables,
            computerChoices: current.computerChoices, callVoiceId: current.callVoiceId, callSpeed: current.callSpeed,
            sttKeyterms: current.sttKeyterms, sttLanguage: current.sttLanguage, sttNoVerbatim: current.sttNoVerbatim,
            sttBatchPauseS: current.sttBatchPauseS, debugRecordingsEnabled: current.debugRecordingsEnabled,
            updatedAt: current.updatedAt)
        return settings
    }
}

final class ComputerModelStoreTests: XCTestCase {
    private func settings(model: String? = nil, effort: String? = nil) throws -> SpokenVoiceSettings {
        let json = """
            {"computer_claude_model": \(model.map { "\"\($0)\"" } ?? "null"),
             "computer_claude_effort": \(effort.map { "\"\($0)\"" } ?? "null"),
             "computer_turn_preset": "normal", "computer_turn_tunables": null,
             "computer_choices": {"claude_models": {"big": ["low", "high"], "small": ["low"]},
               "turn_presets": {"normal": {"end_wait_s": 1.2}}, "tunable_bounds": {},
               "defaults": {"computer_claude_model": "big", "computer_claude_effort": "low",
                            "computer_turn_preset": "normal"}},
             "call_voice_id": null, "call_speed": 1.0, "stt_keyterms": [], "stt_language": null,
             "stt_no_verbatim": false, "stt_batch_pause_s": null, "debug_recordings_enabled": false,
             "updated_at": "2026-11-23T12:00:00+00:00"}
            """
        return try JSONDecoder().decode(SpokenVoiceSettings.self, from: Data(json.utf8))
    }

    /// Unset fields are "the default" and have to go out as `null`: an omitted key would leave a
    /// stored choice in force, so a choice reset to the default would never reset.
    func testTheDefaultIsSentAsNullAndAChoiceAsItself() throws {
        func sent(_ update: ComputerModelUpdate) throws -> [String: Any] {
            try XCTUnwrap(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        }
        let unset = try sent(ComputerModelUpdate(model: nil, effort: nil))
        XCTAssertTrue(unset["computer_claude_model"] is NSNull)
        XCTAssertTrue(unset["computer_claude_effort"] is NSNull)
        XCTAssertEqual(Set(unset.keys), ["computer_claude_model", "computer_claude_effort"])
        let set = try sent(ComputerModelUpdate(model: "big", effort: "high"))
        XCTAssertEqual(set["computer_claude_model"] as? String, "big")
    }

    /// The backend refuses a model and effort that do not go together, so a model change that
    /// strands the effort has to take the effort back rather than send a pair that 400s.
    @MainActor
    func testChoosingAModelThatCannotTakeTheEffortResetsIt() async throws {
        let api = FakeComputerModelApi(settings: try settings(model: "big", effort: "high"))
        let store = ComputerModelStore(api: api)
        await store.load()
        XCTAssertEqual(store.effort, "high")

        await store.choose(model: "small")
        XCTAssertEqual(store.model, "small")
        XCTAssertEqual(store.effort, "", "the new model does not accept high")
        let updates = await api.updates
        XCTAssertEqual(updates, [ComputerModelUpdate(model: "small", effort: nil)])
    }

    @MainActor
    func testChoosingAModelThatTakesTheEffortKeepsIt() async throws {
        let api = FakeComputerModelApi(settings: try settings(model: "big", effort: "low"))
        let store = ComputerModelStore(api: api)
        await store.load()
        await store.choose(model: "small")
        XCTAssertEqual(store.effort, "low")
    }

    func testPresetSummaryReadsTheBackendsNumbers() throws {
        let voice = try JSONDecoder().decode(
            SpokenVoiceSettings.self, from: Data(PaiFixtures.spokenVoiceSettings.utf8))
        let choices = try XCTUnwrap(voice.computerChoices)
        XCTAssertTrue(choices.summary(ofPreset: "patient").contains("3"))
        XCTAssertTrue(choices.summary(ofPreset: "").contains("1.2"), "empty means the default preset")
        XCTAssertTrue(choices.summary(ofPreset: "explicit").contains("computer start"))
    }

    func testTheSettingsPayloadWithoutTheRemovedKeysDecodes() throws {
        let voice = try settings(model: nil, effort: "low")
        XCTAssertEqual(voice.computerChoices?.modelIds, ["big", "small"])
        XCTAssertEqual(voice.computerClaudeEffort, "low")
    }
}
