import XCTest

@testable import PAIKit

final class SettingsCategoryTests: XCTestCase {
    func testTheOwnerHasEveryPageInTwoHalves() {
        let owner = Capabilities(role: .owner)
        XCTAssertEqual(
            SettingsCategory.listed(in: .yours, for: owner).map(\.rawValue),
            ["microphone", "notifications", "voices", "appearance", "location", "devices", "history", "thisPhone"])
        XCTAssertEqual(
            SettingsCategory.listed(in: .administration, for: owner).map(\.rawValue),
            [
                "system", "alerts", "mail", "providers", "models", "integrations", "voiceSound", "agents", "people",
                "diagnostics",
            ])
    }

    func testAGuestHasTheirOwnPagesAndNoAdministration() {
        let guest = Capabilities(role: .guest)
        XCTAssertEqual(
            SettingsCategory.listed(in: .yours, for: guest).map(\.rawValue),
            ["microphone", "notifications", "voices", "appearance", "location", "devices", "history", "thisPhone"])
        XCTAssertTrue(SettingsCategory.listed(in: .administration, for: guest).isEmpty)
    }

    func testBeforeTheRoleIsKnownOnlyWhatReadsNothingFromTheServerIsListed() {
        XCTAssertEqual(
            SettingsCategory.listed(in: .yours, for: .unknown).map(\.rawValue),
            ["microphone", "appearance", "history", "thisPhone"])
        XCTAssertTrue(SettingsCategory.listed(in: .administration, for: .unknown).isEmpty)
    }

    func testEveryPageIsNamedDescribedAndDrawnOnce() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.title.isEmpty, category.rawValue)
            XCTAssertFalse(category.summary.isEmpty, category.rawValue)
            XCTAssertFalse(category.systemImage.isEmpty, category.rawValue)
        }
        XCTAssertEqual(Set(SettingsCategory.allCases.map(\.title)).count, SettingsCategory.allCases.count)
    }

    func testTheListShowsTheValuesThatAreWorthAGlance() {
        let window = SleepWindow.standard
        XCTAssertEqual(
            SettingsCategory.notifications.value(theme: .system, sleepWindow: window, openAlerts: nil),
            "Sleep 22:00–05:00")
        XCTAssertNil(SettingsCategory.notifications.value(theme: .system, sleepWindow: nil, openAlerts: nil))
        XCTAssertEqual(SettingsCategory.appearance.value(theme: .system, sleepWindow: nil, openAlerts: nil), "Auto")
        XCTAssertEqual(SettingsCategory.appearance.value(theme: .dark, sleepWindow: nil, openAlerts: nil), "Dark")
        XCTAssertEqual(SettingsCategory.system.value(theme: .system, sleepWindow: nil, openAlerts: 2), "2 open")
        XCTAssertNil(SettingsCategory.system.value(theme: .system, sleepWindow: nil, openAlerts: 0))
        XCTAssertNil(SettingsCategory.voices.value(theme: .dark, sleepWindow: window, openAlerts: 5))
    }

    func testTheScopeTagsReadTheSameWordsEverywhere() {
        XCTAssertEqual(SettingsScope.synced.label, "Synced")
        XCTAssertEqual(SettingsScope.thisDevice.label, "This iPhone")
        XCTAssertEqual(SettingsScope.everyone.label, "Everyone")
    }
}
