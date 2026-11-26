import Foundation

/// One block as the spec view draws it inside a chain: where it sits (`depth`) and the lines the
/// "waits for" relation adds to its card. The wording is the web's, character for character.
public struct ArcChainEntry: Sendable, Equatable, Identifiable {
    public var id: Int { block.id }
    public let block: ArcTimelineBlock
    /// 0 for a block nobody in its segment makes it wait; one more per prerequisite it hangs under.
    public let depth: Int
    /// "3 wait for this" — on a block other blocks of its segment wait for.
    public let waiterLine: String?
    /// "⏳ waits for #33 <sentence>" — on a block not started yet whose prerequisite is unresolved.
    public let waitsForLine: String?
    /// "also waits for #25" — one per prerequisite the indentation and the line above do not name.
    public let alsoLines: [String]
    /// "same agent as #N" — on a planned leader that names the agent to reuse.
    public let sameAgentLine: String?

    /// Greyed: the block has not started and something it needs is still open.
    public var isWaiting: Bool { waitsForLine != nil }

    public init(
        block: ArcTimelineBlock, depth: Int, waiterLine: String?, waitsForLine: String?, alsoLines: [String],
        sameAgentLine: String?
    ) {
        self.block = block
        self.depth = depth
        self.waiterLine = waiterLine
        self.waitsForLine = waitsForLine
        self.alsoLines = alsoLines
        self.sameAgentLine = sameAgentLine
    }
}

/// Derives the "waits for" chains of one segment from the leaders' `w` lists.
///
/// A block hangs under the first prerequisite in its `w` that sits in the same segment, so a chain
/// stays inside one segment; a prerequisite in an earlier segment is already behind a checkpoint
/// and draws nothing. A block with no such prerequisite starts a column of its own. Columns and
/// the waiters inside them keep the segment's block order.
public enum ArcChains {

    /// One column per root block, each flattened depth-first (a prerequisite, then its waiters).
    public static func columns(for segment: ArcTimelineSegment, in timeline: ArcTimeline) -> [[ArcChainEntry]] {
        var byID: [Int: ArcTimelineBlock] = [:]
        for candidate in timeline.segments {
            for block in candidate.blocks { byID[block.id] = block }
        }
        let inSegment = Set(segment.blocks.map(\.id))

        var parentOf: [Int: Int] = [:]
        var waiterCount: [Int: Int] = [:]
        for block in segment.blocks {
            let prerequisites = block.leader?.w ?? []
            if let parent = prerequisites.first(where: { $0 != block.id && inSegment.contains($0) }) {
                parentOf[block.id] = parent
            }
            for prerequisite in Set(prerequisites) where prerequisite != block.id && inSegment.contains(prerequisite) {
                waiterCount[prerequisite, default: 0] += 1
            }
        }

        var children: [Int: [ArcTimelineBlock]] = [:]
        var roots: [ArcTimelineBlock] = []
        for block in segment.blocks {
            if let parent = parentOf[block.id] {
                children[parent, default: []].append(block)
            } else {
                roots.append(block)
            }
        }

        var columns: [[ArcChainEntry]] = []
        var placed = Set<Int>()
        func append(_ block: ArcTimelineBlock, depth: Int, to column: inout [ArcChainEntry]) {
            guard placed.insert(block.id).inserted else { return }
            column.append(
                entry(
                    for: block, depth: depth, parent: parentOf[block.id], waiters: waiterCount[block.id] ?? 0,
                    blocks: byID))
            for child in children[block.id] ?? [] { append(child, depth: depth + 1, to: &column) }
        }
        for root in roots {
            var column: [ArcChainEntry] = []
            append(root, depth: 0, to: &column)
            columns.append(column)
        }
        // A cycle (the server refuses them) leaves its members parentless-in-no-root; show each
        // as a column of its own rather than dropping the block.
        for block in segment.blocks where !placed.contains(block.id) {
            var column: [ArcChainEntry] = []
            append(block, depth: 0, to: &column)
            columns.append(column)
        }
        return columns
    }

    private static func entry(
        for block: ArcTimelineBlock, depth: Int, parent: Int?, waiters: Int, blocks: [Int: ArcTimelineBlock]
    ) -> ArcChainEntry {
        let prerequisites = block.leader?.w ?? []
        let notStarted = block.leader?.s == .pending

        var headline: Int?
        if notStarted {
            headline = prerequisites.first { id in
                guard let status = blocks[id]?.leader?.s else { return false }
                return status != .done && status != .cancelled
            }
        }
        let named = Set([headline, parent].compactMap { $0 })
        var seen = Set<Int>()
        var also: [String] = []
        for id in prerequisites where id != block.id && !named.contains(id) && seen.insert(id).inserted {
            also.append("also waits for #\(id)")
        }

        var waitsFor: String?
        if let headline {
            waitsFor = "⏳ waits for #\(headline)"
            if let sentence = blocks[headline]?.leader?.i, !sentence.isEmpty { waitsFor? += " \(sentence)" }
        }
        var sameAgent: String?
        if let follows = block.leader?.g?.follows { sameAgent = "same agent as #\(follows)" }

        return ArcChainEntry(
            block: block, depth: depth, waiterLine: waiters > 0 ? "\(waiters) wait for this" : nil,
            waitsForLine: waitsFor, alsoLines: also, sameAgentLine: sameAgent)
    }
}
