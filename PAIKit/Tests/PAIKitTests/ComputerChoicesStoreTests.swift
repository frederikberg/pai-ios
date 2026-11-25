import XCTest

@testable import PAIKit

final class ComputerChoicesStoreTests: XCTestCase {
    func testPresetSummaryReadsTheBackendsNumbers() throws {
        let voice = try JSONDecoder().decode(
            SpokenVoiceSettings.self, from: Data(PaiFixtures.spokenVoiceSettings.utf8))
        let choices = try XCTUnwrap(voice.computerChoices)
        XCTAssertTrue(choices.summary(ofPreset: "patient").contains("3"))
        XCTAssertTrue(choices.summary(ofPreset: "").contains("1.2"), "empty means the default preset")
        XCTAssertTrue(choices.summary(ofPreset: "explicit").contains("computer start"))
    }

    func testAnOlderPayloadWithKeysTheBackendRemovedStillDecodes() throws {
        let voice = try JSONDecoder().decode(
            SpokenVoiceSettings.self,
            from: Data(
                """
                {"computer_engine": "openai_realtime", "computer_voice": "cedar", "computer_speed": 1.2,
                 "computer_choices": {"engines": ["openai_realtime", "claude"], "claude_models": {},
                   "turn_presets": {}, "tunable_bounds": {},
                   "defaults": {"computer_engine": "claude", "computer_claude_model": "m",
                                "computer_claude_effort": "low", "computer_turn_preset": "normal"}},
                 "call_voice_id": null, "call_speed": 1.0, "stt_keyterms": [], "stt_language": null,
                 "stt_no_verbatim": false, "debug_recordings_enabled": false, "updated_at": ""}
                """.utf8))
        XCTAssertEqual(voice.computerChoices?.defaults.computerTurnPreset, "normal")
    }
}
