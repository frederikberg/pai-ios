import Foundation

/// Every session's remembered read position for the life of the process, and the rule for when a
/// scroll may overwrite it.
///
/// The transcript screen is recreated on every navigation into a session, so what a reader left
/// behind has to live outside it. It is also the one place that decides which scrolls count as
/// the reader's position: a scroll callback fires for the app's own layout and landing writes as
/// much as for a finger, and the first ones of a visit show the top of whatever window was cached
/// or the list's own settling. Recorded, they replace the position being restored a moment before
/// it is read, and the reader lands on the first message.
///
/// A visit therefore accepts positions only between its landing and the moment the screen starts
/// to leave: ``beginVisit(sessionId:)`` closes recording, ``finishLanding(sessionId:)`` opens it,
/// ``suspend(sessionId:)`` closes it again for the pop transition's own layout passes.
@MainActor
public final class TranscriptReadPositions {

    private struct Entry {
        var anchor: TranscriptAnchor?
        /// The server's time for this process's last acknowledged save — what tells a position
        /// saved later by another device from this process's own.
        var lastOwnSave: Date?
        var isLanded = false
        var isSuspended = false
        /// Recorded since it was last handed to ``takePendingSave(sessionId:)``.
        var hasUnsavedAnchor = false
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// The position currently remembered for a session.
    public func anchor(for sessionId: String) -> TranscriptAnchor? {
        entries[sessionId]?.anchor
    }

    /// A screen for this session was created: nothing it scrolls counts until it has landed.
    public func beginVisit(sessionId: String) {
        entries[sessionId, default: Entry()].isLanded = false
        entries[sessionId, default: Entry()].isSuspended = false
    }

    /// Resolves the position this visit restores — what the process remembers, unless the server
    /// holds one saved later elsewhere (``TranscriptAnchor/seed(current:persisted:lastOwnSave:)``).
    public func seed(sessionId: String, persisted: PersistedReadPosition?) -> TranscriptAnchor? {
        var entry = entries[sessionId, default: Entry()]
        let seeded = TranscriptAnchor.seed(
            current: entry.anchor, persisted: persisted, lastOwnSave: entry.lastOwnSave)
        entry.anchor = seeded.anchor
        entry.lastOwnSave = seeded.lastOwnSave
        entries[sessionId] = entry
        return seeded.anchor
    }

    /// The restore has been written to the viewport: from here a scroll is the reader's position.
    public func finishLanding(sessionId: String) {
        entries[sessionId, default: Entry()].isLanded = true
    }

    /// The screen is going away. Its own transition re-lays the list out, and those passes must
    /// not replace where the reader was.
    public func suspend(sessionId: String) {
        entries[sessionId, default: Entry()].isSuspended = true
    }

    /// The screen is back in front of the reader (a cancelled pop, a covering screen dismissed).
    public func resume(sessionId: String) {
        entries[sessionId, default: Entry()].isSuspended = false
    }

    /// Remembers `anchor` as the reader's position. Returns whether it was taken.
    @discardableResult
    public func record(_ anchor: TranscriptAnchor, sessionId: String) -> Bool {
        guard var entry = entries[sessionId], entry.isLanded, !entry.isSuspended else { return false }
        entry.anchor = anchor
        entry.hasUnsavedAnchor = true
        entries[sessionId] = entry
        return true
    }

    /// The position to send to the server, once per recorded change; `nil` when nothing was
    /// recorded since the last call, so a visit that only looked never overwrites a newer
    /// position another device saved.
    public func takePendingSave(sessionId: String) -> TranscriptAnchor? {
        guard var entry = entries[sessionId], entry.hasUnsavedAnchor else { return nil }
        entry.hasUnsavedAnchor = false
        entries[sessionId] = entry
        return entry.anchor
    }

    /// The server acknowledged a save at `savedAt`.
    public func recordSave(sessionId: String, savedAt: Date) {
        entries[sessionId, default: Entry()].lastOwnSave = savedAt
    }
}
