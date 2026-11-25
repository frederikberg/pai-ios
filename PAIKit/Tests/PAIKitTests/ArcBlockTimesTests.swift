import Foundation
import XCTest

@testable import PAIKit

/// The block time lines and the agent thread links — the cases of the web's `blockTimeLines` and
/// `agentThreads` tests, so a block reads the same on both clients.
final class ArcBlockTimesTests: XCTestCase {

    private let now = IsoTimestamp.date(from: "2026-11-25T12:00:00+00:00")!

    private func leader(_ g: ArcLeaderAgent) -> ArcRow {
        ArcRow(id: 1, i: nil, src: nil, diff: nil, s: .inProgress, o: 1, k: .leader, b: 1, g: g, n: nil, r: nil, v: nil)
    }

    func test_finishedBlock_showsBerlinStartAndDuration() {
        let g = ArcLeaderAgent(
            type: "aria", startedAt: "2026-11-25T09:03:00+00:00", endedAt: "2026-11-25T09:28:00+00:00")
        XCTAssertEqual(
            ArcBlockTimes.lines(leader: leader(g), state: .accepted, now: now), ["10:03 · 25 min"])
    }

    func test_startWithoutEnd_showsElapsed_andFractionalStampsParse() {
        let g = ArcLeaderAgent(type: "aria", startedAt: "2026-11-25T10:00:00.000000+00:00")
        XCTAssertEqual(
            ArcBlockTimes.lines(leader: leader(g), state: .working, now: now), ["11:00 · running for 2 h"])
    }

    func test_leaderWithoutStamps_showsNothing() {
        XCTAssertEqual(
            ArcBlockTimes.lines(leader: leader(ArcLeaderAgent(type: "aria")), state: .notSpawned, now: now), [])
        XCTAssertEqual(ArcBlockTimes.lines(leader: nil, state: .notSpawned, now: now), [])
    }

    func test_returnedBlock_saysHowLongItHasWaited_onlyWhileReturned() {
        let g = ArcLeaderAgent(type: "aria", name: "a", returnedAt: "2026-11-25T11:35:00+00:00")
        XCTAssertEqual(
            ArcBlockTimes.lines(leader: leader(g), state: .returned, now: now),
            ["returned 25 min ago, awaiting review"])
        XCTAssertEqual(ArcBlockTimes.lines(leader: leader(g), state: .accepted, now: now), [])
    }

    func test_returnedBlock_measuresRunToReturn_notToNow() {
        let g = ArcLeaderAgent(
            type: "aria", name: "a", returnedAt: "2026-11-25T11:35:00+00:00", startedAt: "2026-11-25T10:00:00+00:00")
        XCTAssertEqual(
            ArcBlockTimes.lines(leader: leader(g), state: .returned, now: now),
            ["11:00 · 1 h 35 min", "returned 25 min ago, awaiting review"])
    }

    func test_formatSpan_minutesAreFinestUnit() {
        XCTAssertEqual(ArcBlockTimes.formatSpan(ms: 30_000), "<1 min")
        XCTAssertEqual(ArcBlockTimes.formatSpan(ms: 61 * 60_000), "1 h 1 min")
        XCTAssertEqual(ArcBlockTimes.formatSpan(ms: 27 * 3_600_000), "1 d 3 h")
    }

    func test_leaderStamps_decodeFromTheWire() throws {
        let json = #"{"type":"aria","started_at":"2026-11-25T09:03:00+00:00","ended_at":"2026-11-25T09:28:00+00:00"}"#
        let g = try JSONDecoder().decode(ArcLeaderAgent.self, from: Data(json.utf8))
        XCTAssertEqual(g.startedAt, "2026-11-25T09:03:00+00:00")
        XCTAssertEqual(g.endedAt, "2026-11-25T09:28:00+00:00")
    }

    // MARK: - Threads

    private func lead(_ id: Int, _ o: Double, _ name: String, type: String = "aria") -> ArcRow {
        ArcRow(
            id: id, i: nil, src: nil, diff: nil, s: .pending, o: o, k: .leader, b: id,
            g: ArcLeaderAgent(type: type, name: name), n: nil, r: nil, v: nil)
    }

    func test_threads_linkOneAgentsBlocksAcrossSegmentsInOrder_andNoOneElses() {
        let marker = ArcRow(
            id: 9, i: nil, src: nil, diff: nil, s: nil, o: 5, k: .marker, b: nil, g: nil, n: nil, r: nil, v: nil)
        let rows = [
            lead(1, 1, "a"), lead(2, 2, "b"), marker, lead(3, 6, "a"), lead(4, 7, "a"),
            lead(5, 8, "x", type: "main"), lead(6, 9, "x", type: "main"),
        ]
        let links = ArcBlockTimes.threads(ArcTimelineBuilder.build(rows: rows, busyAgents: []))
        XCTAssertNil(links[1]?.prev)
        XCTAssertEqual(links[1]?.next?.id, 3)
        XCTAssertEqual(links[3]?.prev?.id, 1)
        XCTAssertEqual(links[3]?.next?.id, 4)
        XCTAssertEqual(links[4]?.prev?.id, 3)
        XCTAssertNil(links[4]?.next)
        XCTAssertNil(links[2])
        XCTAssertNil(links[5])
    }
}
