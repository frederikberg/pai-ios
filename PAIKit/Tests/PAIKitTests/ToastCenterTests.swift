import XCTest

@testable import PAIKit

@MainActor
final class ToastCenterTests: XCTestCase {
    /// A bar leaving the screen gives back only its own space: the add button that returns in the
    /// same moment keeps the toasts above itself, whichever of the two reports first.
    func testOneOwnerLeavingKeepsWhatAnotherReserved() async throws {
        let toasts = ToastCenter()
        toasts.reserveBottom(120, for: "bar")
        toasts.reserveBottom(76, for: "button")
        XCTAssertEqual(toasts.bottomBarHeight, 120)
        toasts.reserveBottom(0, for: "bar")
        XCTAssertEqual(toasts.bottomBarHeight, 76)
        toasts.reserveBottom(0, for: "button")
        XCTAssertEqual(toasts.bottomBarHeight, 0)
    }
}
