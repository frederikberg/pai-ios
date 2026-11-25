import XCTest

@testable import PAIKit

/// These two signals arm something a reader did not ask for in the moment it happens — a live
/// microphone, a raised keyboard. Their whole value is that they fire exactly once, and the way
/// they break is silent: a screen that reappears (a rotation, a return from the photo picker, a
/// restored navigation path on a cold launch) would re-arm, and a microphone that starts on its
/// own looks like the app misbehaving rather than like a stale flag.
@MainActor
final class PendingScreenIntentTests: XCTestCase {

    func testACameraRequestIsConsumedOnceAndCanBeCancelled() async {
        let request = CameraLaunchRequest()
        XCTAssertFalse(request.consume())

        request.arm()
        XCTAssertTrue(request.consume())
        XCTAssertFalse(request.consume(), "returning from the camera must not open it again")

        request.arm()
        request.cancel()
        XCTAssertFalse(request.consume())
    }

    func testACallRequestIsConsumedOnce() async {
        let request = CallModeLaunchRequest()
        XCTAssertFalse(request.consume(), "a fresh request must not claim to have been armed")

        request.arm()
        XCTAssertTrue(request.consume())
        XCTAssertFalse(request.consume(), "a second appearance of the same screen must not re-arm")
    }

    /// A screen that was abandoned has to be able to put the request back, or the *next* new
    /// session inherits it — a call nobody asked for, started from a different tile entirely.
    func testACancelledCallRequestIsNotConsumed() async {
        let request = CallModeLaunchRequest()
        request.arm()
        request.cancel()
        XCTAssertFalse(request.consume())
    }

    /// Left set, a call choice from a take that ended would turn a later, unrelated new session
    /// into a call on its second opening.
    func testWhatAVisitLeftIsTakenOnlyOnce() async {
        let carry = NewSessionReturn()
        XCTAssertNil(carry.consume())

        carry.keep(machine: "laptop", startsCall: true)
        XCTAssertEqual(carry.consume(), NewSessionReturn.Kept(machine: "laptop", startsCall: true))
        XCTAssertNil(carry.consume(), "a later opening must start clean")
    }

    func testAFilterFocusRequestIsConsumedOnce() async {
        let focus = NotesFilterFocus()
        XCTAssertFalse(focus.consume())

        focus.arm()
        XCTAssertTrue(focus.consume())
        XCTAssertFalse(focus.consume())
    }
}
