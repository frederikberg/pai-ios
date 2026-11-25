import XCTest

@testable import PAIKit

final class SettingsCategoryTests: XCTestCase {
    func testOnlyTheOwnerHasAdministration() {
        XCTAssertFalse(SettingsCategory.listed(in: .administration, for: Capabilities(role: .owner)).isEmpty)
        XCTAssertTrue(SettingsCategory.listed(in: .administration, for: Capabilities(role: .guest)).isEmpty)
        XCTAssertTrue(SettingsCategory.listed(in: .administration, for: .unknown).isEmpty)
    }

    func testAGuestKeepsTheirOwnPagesAndBeforeTheRoleIsKnownOnlyWhatReadsNothingFromTheServer() {
        let guest = SettingsCategory.listed(in: .yours, for: Capabilities(role: .guest))
        XCTAssertTrue(guest.contains(.voices) && guest.contains(.devices) && guest.contains(.notifications))
        let unknown = SettingsCategory.listed(in: .yours, for: .unknown)
        XCTAssertFalse(unknown.contains(.voices) || unknown.contains(.devices))
        XCTAssertTrue(unknown.contains(.appearance))
    }
}
