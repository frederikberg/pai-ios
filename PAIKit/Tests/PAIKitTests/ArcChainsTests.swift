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

    /// The server refuses a cycle, but its members must still be drawn: each one a root.
    func test_cycle_keepsEveryBlockOnScreenAsARoot() {
        let timeline = build([
            leader(1, "A", w: [2]),
            leader(2, "B", w: [1]),
        ])

        let cols = columns(timeline)

        XCTAssertEqual(cols.map { $0.map(\.block.id) }, [[1], [2]])
    }

    // MARK: - Which lines show

    /// Prerequisites already Done or Cancelled drop out of "also waits for", and a started block
    /// shows no waiting line at all.
    func test_metPrerequisites_dropOut_andStartedBlocksDoNotWait() {
        let timeline = build([
            leader(1, "A", s: .inProgress),
            leader(2, "B", s: .done),
            leader(3, "C", s: .cancelled),
            leader(4, "D", s: .inProgress),
            leader(5, "Waiting", w: [2, 3, 1, 4]),
            leader(6, "Running", s: .inProgress, w: [1]),
        ])

        let entries = columns(timeline).flatMap { $0 }

        let waiting = entries.first { $0.block.id == 5 }
        XCTAssertEqual(waiting?.waitsForLine, "⏳ waits for #1 A")
        XCTAssertEqual(waiting?.alsoLines, ["also waits for #4"])
        let running = entries.first { $0.block.id == 6 }
        XCTAssertNil(running?.waitsForLine)
        XCTAssertEqual(running?.alsoLines, [])
        XCTAssertFalse(running?.isWaiting ?? true)
    }

    func test_oneWaiter_readsWaits() {
        let timeline = build([
            leader(1, "A", s: .inProgress),
            leader(2, "B", w: [1]),
        ])

        XCTAssertEqual(columns(timeline)[0][0].waiterLine, "1 waits for this")
    }

    // MARK: - Checkpoint

    private func row(_ id: Int, b: Int, s: ArcRowStatus, o: Double) -> ArcRow {
        ArcRow(id: id, i: "row", src: "U", diff: 1, s: s, o: o, k: .regular, b: b, g: nil, n: nil, r: nil, v: nil)
    }

    /// A not-started leader after the open segment waits for the checkpoint; an unmet
    /// prerequisite's line wins; a started one and one in the open segment say nothing.
    func test_notStartedLeaderBehindTheOpenSegment_waitsForTheCheckpoint() {
        let timeline = build([
            leader(1, "Open work", s: .inProgress, o: 1),
            leader(8, "Pending in the open segment", o: 1.5),
            marker(2, o: 2),
            leader(3, "Plain", o: 3),
            leader(4, "Has a prerequisite", o: 4, w: [1]),
            leader(5, "Running", s: .inProgress, o: 5),
            marker(6, o: 6),
            leader(7, "Two gates away", o: 7),
        ])

        let open = columns(timeline, segment: 0).flatMap { $0 }
        let second = columns(timeline, segment: 1).flatMap { $0 }
        let third = columns(timeline, segment: 2).flatMap { $0 }

        XCTAssertNil(open.first { $0.block.id == 8 }?.waitsForLine)
        XCTAssertEqual(second.first { $0.block.id == 3 }?.waitsForLine, "⏳ waits for the checkpoint")
        XCTAssertEqual(second.first { $0.block.id == 4 }?.waitsForLine, "⏳ waits for #1 Open work")
        XCTAssertNil(second.first { $0.block.id == 5 }?.waitsForLine)
        XCTAssertEqual(third.first?.waitsForLine, "⏳ waits for the checkpoint")
        XCTAssertTrue(second.first { $0.block.id == 3 }?.isWaiting ?? false)
    }

    /// The open segment is the first with any unresolved row, not only an unresolved leader: a
    /// finished leader with an open row keeps its segment open.
    func test_openSegment_countsRowsAndLooseRows() {
        let timeline = build([
            leader(1, "Done leader", s: .done, o: 1),
            row(11, b: 1, s: .pending, o: 1.1),
            marker(2, o: 2),
            leader(3, "Next", o: 3),
        ])
        XCTAssertEqual(ArcChains.openSegmentIndex(in: timeline), 0)

        let loose = build([
            leader(1, "Done leader", s: .done, o: 1),
            ArcRow(
                id: 12, i: "x", src: "U", diff: 1, s: .pending, o: 1.2, k: .regular, b: nil, g: nil, n: nil, r: nil,
                v: nil),
            marker(2, o: 2),
            leader(3, "Next", o: 3),
        ])
        XCTAssertEqual(ArcChains.openSegmentIndex(in: loose), 0)

        let settled = build([
            leader(1, "Done", s: .done, o: 1), marker(2, o: 2), leader(3, "Also", s: .cancelled, o: 3),
        ])
        XCTAssertNil(ArcChains.openSegmentIndex(in: settled))
        XCTAssertNil(columns(settled, segment: 1).flatMap { $0 }.first?.waitsForLine)
    }

    // MARK: - Same agent

    func test_plannedLeaderThatFollows_readsSameAgentAs() {
        let timeline = build([
            leader(5, "Build", s: .inProgress),
            leader(6, "Fix", w: [5], g: ArcLeaderAgent(type: nil, follows: 5)),
        ])

        let entry = columns(timeline).flatMap { $0 }.first { $0.block.id == 6 }

        XCTAssertEqual(entry?.block.agentLabel, "same agent as #5")
    }

    /// Once the server fills the agent in on start, the agent's own label wins.
    func test_followsWithAType_readsTheAgentLabel() {
        let timeline = build([
            leader(6, "Fix", s: .inProgress, g: ArcLeaderAgent(type: "aria", name: "arc-ios", follows: 5))
        ])

        XCTAssertEqual(columns(timeline)[0][0].block.agentLabel, "aria · arc-ios")
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
