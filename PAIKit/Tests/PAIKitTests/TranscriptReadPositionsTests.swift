import XCTest

@testable import PAIKit

final class TranscriptReadPositionsTests: XCTestCase {

    private let session = "s1"
    private let loaded = [10, 11, 12, 13, 14]

    private func firstRowAtTop() -> TranscriptAnchor {
        TranscriptAnchor(messageId: 10, offset: 0)
    }

    private func leftAtBottom() -> TranscriptAnchor {
        TranscriptAnchor(
            messageId: 13, offset: -300, lastSeen: TranscriptRowPosition(messageId: 14, offset: 420))
    }

    /// Open, jump to the bottom, leave, open again: the second open lands where the first one
    /// ended, however the list's own settling scrolls on the way in and out.
    @MainActor
    func testReopenAfterLeavingAtTheBottomLandsAtTheBottom() async {
        let positions = TranscriptReadPositions()

        positions.beginVisit(sessionId: session)
        _ = positions.seed(sessionId: session, persisted: nil)
        positions.finishLanding(sessionId: session)
        XCTAssertTrue(positions.record(leftAtBottom(), sessionId: session))
        positions.suspend(sessionId: session)
        // The pop transition re-lays the list out and reports the top row.
        XCTAssertFalse(positions.record(firstRowAtTop(), sessionId: session))

        positions.beginVisit(sessionId: session)
        // The cached window is laid out at the top before the tail fetch answers.
        XCTAssertFalse(positions.record(firstRowAtTop(), sessionId: session))
        let anchor = positions.seed(sessionId: session, persisted: nil)

        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: loaded), .bottom)
    }

    @MainActor
    func testReopenAfterLeavingMidListLandsOnThatRow() async {
        let positions = TranscriptReadPositions()
        positions.beginVisit(sessionId: session)
        positions.finishLanding(sessionId: session)
        positions.record(TranscriptAnchor(messageId: 12, offset: 35), sessionId: session)
        positions.suspend(sessionId: session)

        positions.beginVisit(sessionId: session)
        positions.record(firstRowAtTop(), sessionId: session)
        let anchor = positions.seed(sessionId: session, persisted: nil)

        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: loaded), .message(id: 12))
    }

    /// A cancelled pop leaves the screen in front of the reader: scrolling counts again.
    @MainActor
    func testResumeAfterACancelledLeaveRecordsAgain() async {
        let positions = TranscriptReadPositions()
        positions.beginVisit(sessionId: session)
        positions.finishLanding(sessionId: session)
        positions.suspend(sessionId: session)
        positions.resume(sessionId: session)

        XCTAssertTrue(positions.record(leftAtBottom(), sessionId: session))
    }

    /// A visit that only looked has nothing to save, so it cannot overwrite a position another
    /// device saved meanwhile; one scroll is saved once.
    @MainActor
    func testOnlyARecordedPositionIsSaved() async {
        let positions = TranscriptReadPositions()
        positions.beginVisit(sessionId: session)
        positions.finishLanding(sessionId: session)
        XCTAssertNil(positions.takePendingSave(sessionId: session))

        positions.record(leftAtBottom(), sessionId: session)
        XCTAssertEqual(positions.takePendingSave(sessionId: session), leftAtBottom())
        XCTAssertNil(positions.takePendingSave(sessionId: session))
    }

    /// The server's newer position still wins over the remembered one, through the same seed.
    @MainActor
    func testAPositionSavedElsewhereLaterReplacesTheRememberedOne() async {
        let positions = TranscriptReadPositions()
        positions.beginVisit(sessionId: session)
        positions.finishLanding(sessionId: session)
        positions.record(TranscriptAnchor(messageId: 12, offset: 35), sessionId: session)
        positions.recordSave(sessionId: session, savedAt: Date(timeIntervalSince1970: 100))

        positions.beginVisit(sessionId: session)
        let anchor = positions.seed(
            sessionId: session,
            persisted: PersistedReadPosition(
                messageId: 11, offsetPx: 5, atBottom: false, savedAt: Date(timeIntervalSince1970: 200)))

        XCTAssertEqual(anchor?.messageId, 11)
    }
}
