import Foundation
import XCTest

@testable import PAIKit

/// The "waits for" chains: which block hangs under which, and the lines each card gets. The wire
/// decode is tolerant of a server that predates the fields.
final class ArcChainsTests: XCTestCase {

    private func leader(
        _ block: Int, _ sentence: String, s: ArcRowStatus = .pending, o: Double? = nil, w: [Int] = [],
        g: ArcLeaderAgent? = nil
    ) -> ArcRow {
        ArcRow(
            id: block * 10, i: sentence, src: "U", diff: 1, s: s, o: o ?? Double(block), k: .leader, b: block, g: g,
            n: nil, r: nil, v: nil, w: w)
    }

    private func marker(_ id: Int, o: Double) -> ArcRow {
        ArcRow(id: id, i: "gate", src: "U", diff: nil, s: nil, o: o, k: .marker, b: nil, g: nil, n: nil, r: nil, v: nil)
    }

    private func build(_ rows: [ArcRow]) -> ArcTimeline {
        ArcTimelineBuilder.build(rows: rows, busyAgents: [])
    }

    private func columns(_ timeline: ArcTimeline, segment: Int = 0) -> [[ArcChainEntry]] {
        ArcChains.columns(for: timeline.segments[segment], in: timeline)
    }

    // MARK: - The mockup's segment

    /// Design, server, iPhone and web on the design; a red team with two fixes behind it. Three
    /// waiters under one prerequisite must come out indented under it, in block order, and the two
    /// fixes behind the not-started red team must read as waiting.
    func test_mockupSegment_nestsWaitersUnderTheirPrerequisite() {
        let timeline = build([
            leader(23, "Reminder design", s: .done),
            leader(25, "Reminders on the server", s: .done, w: [23]),
            leader(29, "Reminders on iPhone", s: .inProgress, w: [23]),
            leader(30, "Reminders on web", s: .done, w: [23]),
            leader(33, "Red team", s: .inProgress),
            leader(34, "Fixes server and web", w: [33]),
            leader(35, "Fixes iPhone", w: [33]),
            leader(27, "Quick Actions editor", s: .done, o: 99),
        ])

        let cols = columns(timeline)

        XCTAssertEqual(cols.map { $0.map(\.block.id) }, [[23, 25, 29, 30], [33, 34, 35], [27]])
        XCTAssertEqual(cols[0].map(\.depth), [0, 1, 1, 1])
        XCTAssertEqual(cols[0][0].waiterLine, "3 wait for this")
        XCTAssertEqual(cols[1][0].waiterLine, "2 wait for this")
        XCTAssertNil(cols[2][0].waiterLine)
        XCTAssertEqual(cols[1][1].waitsForLine, "⏳ waits for #33 Red team")
        XCTAssertTrue(cols[1][1].isWaiting)
        // The design is done, so its waiters are not greyed whatever their own state.
        XCTAssertNil(cols[0][2].waitsForLine)
    }

    // MARK: - Several prerequisites

    /// A waiter on two prerequisites in the segment hangs under the first listed and names the
    /// other; and it is the OPEN one the greyed line names, not simply the first listed.
    func test_twoPrerequisites_hangUnderFirst_andNameTheOther() {
        let timeline = build([
            leader(24, "Server", s: .done),
            leader(25, "Web", s: .inProgress),
            leader(26, "Release notes", w: [24, 25]),
        ])

        let entry = columns(timeline).flatMap { $0 }.first { $0.block.id == 26 }

        XCTAssertEqual(entry?.depth, 1)
        XCTAssertEqual(entry?.waitsForLine, "⏳ waits for #25 Web")
        XCTAssertEqual(entry?.alsoLines, [])
        let nested = columns(timeline).first { $0.contains { $0.block.id == 26 } }
        XCTAssertEqual(nested?.map(\.block.id), [24, 26])
    }

    func test_thirdPrerequisite_isNamedAsAlso() {
        let timeline = build([
            leader(1, "A", s: .inProgress),
            leader(2, "B", s: .inProgress),
            leader(3, "C", s: .inProgress),
            leader(4, "D", w: [1, 2, 3]),
        ])

        let entry = columns(timeline).flatMap { $0 }.first { $0.block.id == 4 }

        XCTAssertEqual(entry?.waitsForLine, "⏳ waits for #1 A")
        XCTAssertEqual(entry?.alsoLines, ["also waits for #2", "also waits for #3"])
    }

    // MARK: - Segments

    /// A prerequisite behind an earlier checkpoint draws no indentation: the waiter is a root of
    /// its own segment. The greyed line still names it while it is open.
    func test_prerequisiteInEarlierSegment_doesNotNest() {
        let timeline = build([
            leader(1, "Before the gate", s: .inProgress, o: 1),
            marker(2, o: 2),
            leader(3, "After the gate", o: 3, w: [1]),
        ])

        let cols = columns(timeline, segment: 1)

        XCTAssertEqual(cols.map { $0.map(\.block.id) }, [[3]])
        XCTAssertEqual(cols[0][0].depth, 0)
        XCTAssertEqual(cols[0][0].waitsForLine, "⏳ waits for #1 Before the gate")
    }

    // MARK: - Chains of chains, and a cycle

    func test_waiterOfAWaiter_isIndentedTwice() {
        let timeline = build([
            leader(1, "A", s: .inProgress),
            leader(2, "B", w: [1]),
            leader(3, "C", w: [2]),
        ])

        XCTAssertEqual(columns(timeline).map { $0.map(\.depth) }, [[0, 1, 2]])
    }

    /// The server refuses a cycle, but a block in one must still be drawn rather than dropped.
    func test_cycle_keepsEveryBlockOnScreen() {
        let timeline = build([
            leader(1, "A", w: [2]),
            leader(2, "B", w: [1]),
        ])

        let ids = columns(timeline).flatMap { $0 }.map(\.block.id)

        XCTAssertEqual(ids.sorted(), [1, 2])
    }

    // MARK: - Same agent

    func test_plannedLeaderThatFollows_readsSameAgentAs() {
        let timeline = build([
            leader(5, "Build", s: .inProgress),
            leader(6, "Fix", w: [5], g: ArcLeaderAgent(type: nil, follows: 5)),
        ])

        let entry = columns(timeline).flatMap { $0 }.first { $0.block.id == 6 }

        XCTAssertEqual(entry?.sameAgentLine, "same agent as #5")
    }

    // MARK: - Wire decode

    /// A server without the fields still decodes: `w` empty, no `follows`.
    func test_decode_toleratesMissingWaitsAndFollows() throws {
        let json = #"{"id": 7, "k": "L", "s": "P", "b": 3, "g": {"type": "aria"}}"#

        let row = try JSONDecoder().decode(ArcRow.self, from: Data(json.utf8))

        XCTAssertEqual(row.w, [])
        XCTAssertNil(row.g?.follows)
    }

    func test_decode_readsWaitsAndFollows() throws {
        let json = #"{"id": 7, "k": "L", "s": "P", "b": 3, "w": [2, 5], "g": {"follows": 5}}"#

        let row = try JSONDecoder().decode(ArcRow.self, from: Data(json.utf8))

        XCTAssertEqual(row.w, [2, 5])
        XCTAssertEqual(row.g?.follows, 5)
    }
}
