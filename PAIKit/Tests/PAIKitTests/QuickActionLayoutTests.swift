import XCTest

@testable import PAIKit

final class QuickActionLayoutTests: XCTestCase {

    private var placed: [QuickAction] {
        QuickActionLayout.grid.flatMap { $0 }.compactMap { slot in
            if case .action(let action) = slot { return action }
            return nil
        }
    }

    func testEveryRowHasOneCellPerColumn() {
        for row in QuickActionLayout.grid {
            XCTAssertEqual(row.count, QuickActionLayout.columns)
        }
    }

    func testMoreSitsTopRight() {
        XCTAssertEqual(QuickActionLayout.grid[0][QuickActionLayout.columns - 1], .more)
        XCTAssertEqual(QuickActionLayout.grid.flatMap { $0 }.filter { $0 == .more }.count, 1)
    }

    /// An action on the grid and in More at once, or in neither, is a tile that is duplicated or
    /// unreachable.
    func testEveryActionIsOnTheGridOrInMoreExactlyOnce() {
        let everything = placed + QuickActionLayout.overflow
        XCTAssertEqual(everything.count, QuickAction.allCases.count)
        XCTAssertEqual(Set(everything), Set(QuickAction.allCases))
    }

    func testFastModesLeadTheOverflow() {
        XCTAssertEqual(Array(QuickActionLayout.overflow.prefix(2)), [.fastSession, .fastCall])
    }

    func testUltrafastCallSitsBelowTheCamera() {
        XCTAssertEqual(QuickActionLayout.grid[2][2], .action(.ultrafastCamera))
        XCTAssertEqual(QuickActionLayout.grid[3][2], .action(.ultrafastCall))
    }

    func testSessionActionsKnowTheirTypeAndMode() {
        XCTAssertEqual(QuickAction.fastCall.sessionType, "fast")
        XCTAssertTrue(QuickAction.fastCall.startsCall)
        XCTAssertFalse(QuickAction.fastSession.startsCall)
        for action in QuickAction.allCases where action.sessionType != nil {
            XCTAssertTrue(action.isSessionAction, "\(action)")
        }
        XCTAssertFalse(QuickAction.me.isSessionAction)
    }

    func testShortcutSlotsAreOneToThree() {
        XCTAssertEqual(QuickAction.allCases.compactMap(\.shortcutSlot), [1, 2, 3])
    }

    func testSummaryReadsRowByRow() {
        XCTAssertEqual(
            QuickActionLayout.summary,
            "selfReport,me,more|computer,home,ultrafast|mailverdict,homeCall,ultrafastCamera|-,-,ultrafastCall")
    }
}
