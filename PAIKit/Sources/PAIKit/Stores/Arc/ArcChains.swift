import Foundation

/// One block as the spec view draws it inside a chain: where it sits (`depth`) and the lines the
/// "waits for" relation adds to its card. The wording is the web's, character for character.
public struct ArcChainEntry: Sendable, Equatable, Identifiable {
    public var id: Int { block.id }
    public let block: ArcTimelineBlock
    /// 0 for a block nobody in its segment makes it wait; one more per prerequisite it hangs under.
    public let depth: Int
    /// "3 wait for this" ("1 waits for this") — on a block other blocks of its segment wait for.
    public let waiterLine: String?
    /// "⏳ waits for #33 <sentence>" — on a block not started yet, for its first unmet prerequisite;
    /// "⏳ waits for the checkpoint" when it has none but its segment lies after the open one.
    public let waitsForLine: String?
    /// "also waits for #25" — one per further unmet prerequisite.
    public let alsoLines: [String]

    /// Greyed: the block has not started and something it needs is still open.
    public var isWaiting: Bool { waitsForLine != nil }

    public init(
        block: ArcTimelineBlock, depth: Int, waiterLine: String?, waitsForLine: String?, alsoLines: [String]
    ) {
        self.block = block
        self.depth = depth
        self.waiterLine = waiterLine
        self.waitsForLine = waitsForLine
        self.alsoLines = alsoLines
    }
}

/// Derives the "waits for" chains of one segment from the leaders' `w` lists.
///
/// A block hangs under the first prerequisite in its `w` that sits in the same segment, so a chain
/// stays inside one segment. A prerequisite in an earlier segment places nothing, but while it is
/// unmet it still prints the waits-for line. A not-started block with no unmet prerequisite in a
/// segment after the open one reads "⏳ waits for the checkpoint". A block with no in-segment
/// prerequisite starts a column of its own. Columns and the waiters inside them keep the
/// segment's block order.
public enum ArcChains {

    /// One column per root block, each flattened depth-first (a prerequisite, then its waiters).
    public static func columns(for segment: ArcTimelineSegment, in timeline: ArcTimeline) -> [[ArcChainEntry]] {
        let open = openSegmentIndex(in: timeline)
        let behindCheckpoint = open.map { segment.index > $0 } ?? false
        var byID: [Int: ArcTimelineBlock] = [:]
        for candidate in timeline.segments {
            for block in candidate.blocks { byID[block.id] = block }
        }
        let inSegment = Set(segment.blocks.map(\.id))

        var parentOf: [Int: Int] = [:]
        var waiterCount: [Int: Int] = [:]
        for block in segment.blocks {
            let prerequisites = (block.leader?.w ?? []).filter { $0 != block.id && inSegment.contains($0) }
            for prerequisite in Set(prerequisites) { waiterCount[prerequisite, default: 0] += 1 }
            if let first = prerequisites.first { parentOf[block.id] = first }
        }

        // Whether following parents from `start` reaches `target`: attaching `target` under
        // `start` would then close a loop.
        func reaches(_ start: Int, _ target: Int) -> Bool {
            var seen = Set<Int>()
            var current: Int? = start
            while let id = current, !seen.contains(id) {
                if id == target { return true }
                seen.insert(id)
                current = parentOf[id]
            }
            return false
        }

        var children: [Int: [ArcTimelineBlock]] = [:]
        var roots: [ArcTimelineBlock] = []
        for block in segment.blocks {
            if let parent = parentOf[block.id], !reaches(parent, block.id) {
                children[parent, default: []].append(block)
            } else {
                roots.append(block)
            }
        }

        func flatten(_ block: ArcTimelineBlock, depth: Int, into column: inout [ArcChainEntry]) {
            column.append(
                entry(
                    for: block, depth: depth, waiters: waiterCount[block.id] ?? 0, blocks: byID,
                    behindCheckpoint: behindCheckpoint))
            for child in children[block.id] ?? [] { flatten(child, depth: depth + 1, into: &column) }
        }
        return roots.map { root in
            var column: [ArcChainEntry] = []
            flatten(root, depth: 0, into: &column)
            return column
        }
    }

    private static func entry(
        for block: ArcTimelineBlock, depth: Int, waiters: Int, blocks: [Int: ArcTimelineBlock],
        behindCheckpoint: Bool
    ) -> ArcChainEntry {
        // Only a block that has not started waits; each prerequisite whose leader is neither
        // Done nor Cancelled is still unmet.
        var unmet: [ArcTimelineBlock] = []
        if block.leader?.s == .pending {
            var seen = Set<Int>()
            for id in block.leader?.w ?? [] where seen.insert(id).inserted {
                guard let prerequisite = blocks[id] else { continue }
                let status = prerequisite.leader?.s
                if status == .done || status == .cancelled { continue }
                unmet.append(prerequisite)
            }
        }

        var waitsFor: String?
        if let first = unmet.first {
            waitsFor = "⏳ waits for #\(first.id)"
            if let sentence = first.leader?.i, !sentence.isEmpty { waitsFor? += " \(sentence)" }
        } else if behindCheckpoint && block.leader?.s == .pending {
            waitsFor = "⏳ waits for the checkpoint"
        }
        return ArcChainEntry(
            block: block, depth: depth,
            waiterLine: waiters > 0 ? "\(waiters) \(waiters == 1 ? "waits" : "wait") for this" : nil,
            waitsForLine: waitsFor, alsoLines: unmet.dropFirst().map { "also waits for #\($0.id)" })
    }

    /// The open segment: the earliest one holding a non-marker row that is neither Done nor
    /// Cancelled. `nil` when everything is resolved.
    public static func openSegmentIndex(in timeline: ArcTimeline) -> Int? {
        func unresolved(_ row: ArcRow) -> Bool { row.s != .done && row.s != .cancelled }
        return timeline.segments.first { segment in
            segment.looseRows.contains(where: unresolved)
                || segment.blocks.contains { block in
                    block.leader.map(unresolved) ?? false || block.rows.contains(where: unresolved)
                }
        }?.index
    }
}
