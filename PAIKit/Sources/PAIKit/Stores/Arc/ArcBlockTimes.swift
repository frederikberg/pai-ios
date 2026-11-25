import Foundation

/// The time lines a block shows and the links between blocks one agent worked in turn — a Swift
/// port of `blockTimeLines`, `formatSpan` and `agentThreads` in the web's `arcModel.ts`.
public enum ArcBlockTimes {

    /// A length of time at minute granularity: `<1 min`, `25 min`, `2 h 5 min`, `1 d 3 h`.
    /// Minutes are the finest unit, so a card that is not redrawn stays truthful to the eye.
    public static func formatSpan(ms: Int) -> String {
        let mins = max(0, ms) / 60_000
        if mins < 1 { return "<1 min" }
        if mins < 60 { return "\(mins) min" }
        let hours = mins / 60
        if hours < 24 { return mins % 60 > 0 ? "\(hours) h \(mins % 60) min" : "\(hours) h" }
        return hours % 24 > 0 ? "\(hours / 24) d \(hours % 24) h" : "\(hours / 24) d"
    }

    /// When the block ran (`Berlin start · duration`, or `· running for X` while no end is known)
    /// and, for a `returned` block, how long it has waited for the main agent. Read off the
    /// server's stamps on the leader's `g`, never off segment placement. Empty for a leader
    /// without them, so older specs render as before. Computed from `now` at render; nothing
    /// ticks.
    public static func lines(leader: ArcRow?, state: ArcBadgeState, now: Date) -> [String] {
        guard let g = leader?.g else { return [] }
        let nowMs = milliseconds(now)
        var lines: [String] = []
        if let startMs = g.startedAt.flatMap(IsoTimestamp.date(from:)).map(milliseconds) {
            let start = SchedulerRunDisplay.formatBerlinEnd(ms: startMs, sinceMs: nowMs)
            // The run ends where the agent handed back, not where the main agent accepted: a run
            // accepted hours later would otherwise read as hours of agent work. A hand-back
            // stamped before the start belongs to an earlier run, and a busy agent has not
            // handed back at all.
            let returnedMs = g.returnedAt.flatMap(IsoTimestamp.date(from:)).map(milliseconds)
            let endedMs = g.endedAt.flatMap(IsoTimestamp.date(from:)).map(milliseconds)
            var endMs = endedMs
            if let returnedMs, returnedMs >= startMs, state != .working { endMs = returnedMs }
            if let endMs {
                lines.append("\(start) · \(formatSpan(ms: endMs - startMs))")
            } else {
                lines.append("\(start) · running for \(formatSpan(ms: nowMs - startMs))")
            }
        }
        if state == .returned, let returnedMs = g.returnedAt.flatMap(IsoTimestamp.date(from:)).map(milliseconds) {
            lines.append("returned \(formatSpan(ms: nowMs - returnedMs)) ago, awaiting review")
        }
        return lines
    }

    /// The blocks one agent worked either side of a block.
    public struct ThreadLinks: Sendable, Equatable {
        public let prev: ArcTimelineBlock?
        public let next: ArcTimelineBlock?
    }

    /// Blocks one agent worked in turn: leaders sharing `g.type` and `g.name`, ordered by `o`
    /// across every segment, each linked to the one before and after. Two leaders that both
    /// carry an `agent_id` link only when it matches: a cancelled block frees its name, so a
    /// fresh agent respawned under it is not a continuation. The main session and unnamed
    /// leaders never link; only blocks with a neighbour appear in the result.
    public static func threads(_ timeline: ArcTimeline) -> [Int: ThreadLinks] {
        var byAgent: [String: [ArcTimelineBlock]] = [:]
        for block in timeline.segments.flatMap(\.blocks) {
            guard let g = block.leader?.g, let name = g.name, !name.isEmpty, g.type != "main" else { continue }
            byAgent["\(g.type ?? "")\u{0}\(name)", default: []].append(block)
        }
        var out: [Int: ThreadLinks] = [:]
        for var list in byAgent.values where list.count > 1 {
            list.sort { lhs, rhs in
                let lo = lhs.leader?.o ?? 0, ro = rhs.leader?.o ?? 0
                return lo != ro ? lo < ro : lhs.id < rhs.id
            }
            for (i, block) in list.enumerated() {
                let prev = i > 0 && sameAgent(list[i - 1], block) ? list[i - 1] : nil
                let next = i + 1 < list.count && sameAgent(block, list[i + 1]) ? list[i + 1] : nil
                if prev != nil || next != nil { out[block.id] = ThreadLinks(prev: prev, next: next) }
            }
        }
        return out
    }

    private static func sameAgent(_ a: ArcTimelineBlock, _ b: ArcTimelineBlock) -> Bool {
        guard let idA = a.leader?.g?.agentId, let idB = b.leader?.g?.agentId else { return true }
        return idA == idB
    }

    private static func milliseconds(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }
}
