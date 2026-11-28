import Foundation
import Observation

/// Composer text kept on the server so every one of the user's clients shows the same half-written
/// message. Swift port of `pai-cloud/web/src/stores/drafts.ts`'s version-ordered rewrite.
///
/// **The device being typed on owns the text.** A composer's field reads this store's own local
/// copy only; nothing coming from the network may replace a value the user is looking at unless
/// the local copy is clean *and* the server proves the change is strictly newer
/// (``syncFromServer()``'s `version` comparison). Adopting on mere inequality — the previous
/// design — is the bug this rewrite exists to close: a poll response produced *before* a flush
/// this device already sent, but delivered *after* that flush's own answer, used to pass every
/// staleness guard and replace the field with older text. `version` makes that ordering explicit
/// instead of inferred from an opaque, unordered `updated_at` token.
///
/// **A relaunch restores `drafts` from `localPersistence`, mirroring the web's own
/// `localStorage`/`loadStored()` contract.** Restoring is never a local claim on anything it
/// names — it populates `drafts` alone, with no pending write and no `knownVersion` bump — so the
/// very first ``syncFromServer()`` afterwards adopts the server's row whenever its version is
/// newer and drops this one's claim on that key if the server has since moved past it, exactly as
/// any other unclaimed key would be treated.
///
/// `@MainActor`, matching `TranscriptStore` — every realistic caller is UI-driven.
@MainActor
@Observable
public final class DraftStore {

    /// Long enough that ordinary typing produces one request; short enough that switching device
    /// right after typing finds the draft already there. Cross-device
    /// text sync is "pick up where I left off", not real-time mirroring — seconds of lag is fine.
    public static let flushDebounceSeconds: TimeInterval = 2

    public internal(set) var drafts: [String: DraftEntry] = [:] {
        didSet { localPersistence?.setValue(drafts, forKey: Keys.localDrafts) }
    }
    /// One-shot signal: bumped whenever a New Session launch choice is made by tapping something
    /// that would otherwise steal focus from the composer, so a view can reclaim it. Never reset
    /// — a consumer reacts to the bump itself, not to a boolean.
    public internal(set) var composerFocusNonce = 0

    private enum Keys {
        static let localDrafts = "drafts.local"
        static let deviceId = "drafts.deviceId"
    }

    private let api: any DraftsFetching
    private let clock: WallClock
    private let scheduler: DraftScheduler
    /// `nil` in every test and in any caller that does not care — the app wires its own shared
    /// log in. Logs only the events that decide whether text survives (a clear, a flush, a sync
    /// dropping a key), never every edit: a live take writes this store many times a second, and a
    /// line per keystroke would flood the very log meant to make a loss like this one legible.
    private let diagnosticsLog: VoiceDiagnosticsLog?
    /// `nil` in every test that does not care, exactly like `diagnosticsLog` — the app wires its
    /// own `UserDefaults` in. See ``drafts`` for what is restored from it and why.
    private let localPersistence: SettingsKeyValueStore?
    /// This device's own id — a uuid minted once and persisted, sent with every write purely for
    /// diagnostics and the "recording on <device>" hint. Never consulted for an ownership
    /// decision, here or server-side.
    public let deviceId: String

    /// Told, for every draft a poll lists, which attachment ids the server holds and when that
    /// request left. The app's staging store uses it to drop an upload another device's send
    /// already claimed; it lives outside this store because it owns the local bytes.
    public var serverAttachmentsObserved: ((_ key: String, _ ids: Set<String>, _ requestedAt: Date) -> Void)?

    /// The debounce timer for a key's next flush — also where a failed write's retry backoff
    /// lives, so a fresh edit's own debounce naturally cancels and replaces a pending retry rather
    /// than the two racing each other.
    private var pendingDebounce: [String: Task<Void, Never>] = [:]
    /// The network call presently in flight for a key — a write (`.write`) or an explicit discard
    /// (`.delete`). At most one at a time, by construction: everything that wants to touch the
    /// server for a key goes through ``requestOp(_:_:)``, which either starts this or queues.
    private var currentOp: [String: Task<Void, Never>] = [:]
    /// What to do again the moment `currentOp[key]` finishes — coalescing, never fan-out. A write
    /// requested while one is already in flight for the same key sets this rather than starting a
    /// second request; the in-flight request's own completion is what fires the queued one, with
    /// whatever text is current *then*, not whatever it was when it was queued. At most one
    /// pending op per key: the most recently requested op wins, matching "last writer wins" — an
    /// edit queued behind an in-flight delete supersedes the delete's own re-queue and vice versa.
    private var queuedOp: [String: PendingOp] = [:]
    /// Bumped on every local change to a key. A poll whose request left before a change carries
    /// that key's older server copy, however its response is ordered against the write.
    private var localRevision: [String: Int] = [:]
    /// Consecutive failed flush attempts per key — what `scheduleRetry` doubles the wait on, and
    /// what a fresh edit (`scheduleFlush`) resets, so a retry backoff never survives past the
    /// edit it was retrying.
    private var retryAttempt: [String: Int] = [:]

    /// Attachment ids a message has been composed with, per key — from Send until the message is
    /// abandoned. The server keeps listing such a row until the send request claims it, and a
    /// poll answered before that claim can arrive after it, so neither a fresh nor a stale
    /// response may put the chip back. Only ever used to hide rows.
    private var withheldAttachmentIds: [String: Set<String>] = [:]

    /// The fields this device changed per key that no write has carried to the server yet. A key
    /// with none has nothing to write, so a flush of it sends nothing, and a newer row is merged
    /// field by field around the ones it has (``syncFromServer()``). Never persisted: a restored
    /// entry is no claim on anything, as above.
    private var unwrittenFields: [String: Set<DraftField>] = [:]
    /// Whether a draft listing has answered since this store was made. Until one has, nothing here
    /// knows what the server holds, and an entry written from that state can replace another
    /// device's text or choices with this one's empty or stale copy; such writes wait in
    /// `awaitingListing` and go out once the listing has been merged.
    var hasListed = false
    private var awaitingListing: Set<String> = []

    private enum PendingOp: Equatable { case write, delete }

    public init(
        api: some DraftsFetching, clock: WallClock = SystemWallClock(),
        scheduler: DraftScheduler = RealDraftScheduler(),
        diagnosticsLog: VoiceDiagnosticsLog? = nil,
        localPersistence: SettingsKeyValueStore? = nil
    ) {
        self.api = api
        self.clock = clock
        self.scheduler = scheduler
        self.diagnosticsLog = diagnosticsLog
        self.localPersistence = localPersistence
        drafts = localPersistence?.value(forKey: Keys.localDrafts) ?? [:]
        if let existing: String = localPersistence?.value(forKey: Keys.deviceId) {
            deviceId = existing
        } else {
            let minted = UUID().uuidString
            deviceId = minted
            localPersistence?.setValue(minted, forKey: Keys.deviceId)
        }
    }

    /// The draft for a key, or an empty one — callers never handle a missing entry themselves.
    public func draft(for key: String) -> DraftEntry {
        drafts[key] ?? .empty
    }

    public func requestComposerFocus() {
        composerFocusNonce += 1
    }

    // MARK: - Editing

    /// Writes the human's own text — and, during a live dictation take, the machine's assembled
    /// text too, through this exact same setter: there is only one owner of the field, whichever
    /// is currently writing to it, never two competing representations.
    public func setDraftText(key: String, text: String) {
        let before = draft(for: key)
        var entry = before
        entry.text = text
        drafts[key] = entry
        scheduleFlush(key, since: before)
    }

    /// The composer's "Restore earlier version" action — writes `previousText` back as the
    /// current text through the ordinary setter, exactly as if it had been typed. The plus menu
    /// only ever offers this when `previousText` is non-empty and differs from `text`; this method
    /// itself stays defensive about that so a stale menu tap can never write an empty string over
    /// something real.
    public func restorePreviousText(key: String) {
        guard let previous = draft(for: key).previousText, !previous.isEmpty else { return }
        setDraftText(key: key, text: previous)
    }

    /// A discard is fire-and-forget, so its answer can land after a write this device made since —
    /// in which case it describes an older state of the row and must not move the restore target
    /// backwards onto the discarded text. `version == nil` means there was no row at all to
    /// discard: nothing was destroyed and there is no version to record.
    private func applyDiscardResult(key: String, result: PaiDraftDeleteResult) {
        guard let version = result.version else { return }
        guard var current = drafts[key] else { return }
        if (current.knownVersion ?? -1) > version { return }
        current.knownVersion = version
        current.previousText = result.previousText
        drafts[key] = current
    }

    /// Launch choices for the next session, held in the `new` draft only.
    /// Any type but Custom drops a previously chosen directory, the same coupling as
    /// `selectWorkingDir` from the other side — or a relaunch restores the directory and with it
    /// the custom session the type pill said it was not.
    public func selectSessionType(_ id: String?) {
        let before = draft(for: DraftKey.newSession)
        var entry = before
        // The API sessions name their models by wire id (each kind from its own catalogue) and the
        // others by alias.
        let apiTypes: Set<String?> = [
            CreateSessionStore.ultrafastSessionTypeId, CreateSessionStore.mailverdictSessionTypeId,
        ]
        if id != entry.sessionType, apiTypes.contains(id) || apiTypes.contains(entry.sessionType) {
            entry.model = nil
            entry.thinking = nil
        }
        entry.sessionType = id
        if id != "custom" { entry.workingDir = nil }
        drafts[DraftKey.newSession] = entry
        scheduleFlush(DraftKey.newSession, since: before)
    }

    /// A chosen directory is what makes a session custom, so the two always move together: a
    /// real path stamps `sessionType = "custom"`, and clearing the path clears the type with it.
    public func selectWorkingDir(_ path: String?) {
        let before = draft(for: DraftKey.newSession)
        var entry = before
        entry.workingDir = path
        entry.sessionType = path != nil ? "custom" : nil
        drafts[DraftKey.newSession] = entry
        scheduleFlush(DraftKey.newSession, since: before)
    }

    public func selectModel(_ id: String?) {
        let before = draft(for: DraftKey.newSession)
        var entry = before
        entry.model = id
        // The set of thinking levels a model accepts is a property of that model
        // (`GET /api/session-models`), so a level chosen for the previous one is not necessarily
        // valid for this one — clear it rather than risk sending a combination the launch would
        // reject.
        entry.thinking = nil
        drafts[DraftKey.newSession] = entry
        scheduleFlush(DraftKey.newSession, since: before)
    }

    public func selectThinking(_ id: String?) {
        let before = draft(for: DraftKey.newSession)
        var entry = before
        entry.thinking = id
        drafts[DraftKey.newSession] = entry
        scheduleFlush(DraftKey.newSession, since: before)
    }

    /// Independent of the model and thinking choices: switching either leaves it alone.
    public func selectNoMemory(_ on: Bool) {
        let before = draft(for: DraftKey.newSession)
        var entry = before
        entry.noMemory = on
        drafts[DraftKey.newSession] = entry
        scheduleFlush(DraftKey.newSession, since: before)
    }

    /// A value the app fills in by itself (every opening of the new-session screen resetting the
    /// model and the no-memory switch), as opposed to the `select…` setters, which are the person's
    /// choice. Changed and used locally, never an edit: nothing is written for it, any unwritten
    /// change of those fields is dropped, and a newer row replaces it like anything else unchanged.
    public func applyDefaults(key: String = DraftKey.newSession, _ change: (inout DraftEntry) -> Void) {
        let before = draft(for: key)
        var entry = before
        change(&entry)
        guard entry != before else { return }
        drafts[key] = entry
        let touched = DraftField.changed(from: before, to: entry)
        guard var unwritten = unwrittenFields[key] else { return }
        unwritten.subtract(touched)
        unwrittenFields[key] = unwritten.isEmpty ? nil : unwritten
        if unwritten.isEmpty {
            pendingDebounce[key]?.cancel()
            pendingDebounce[key] = nil
            retryAttempt[key] = nil
            awaitingListing.remove(key)
        }
    }

    // MARK: - Attachments

    /// Uploads a staged file onto this draft immediately — not debounced like `setDraftText`,
    /// since there is nothing to coalesce: each attachment is its own request, made once, the
    /// moment it is picked. `nil` on failure; the caller (`StagedAttachmentStore`) is what keeps
    /// the bytes around to fall back to sending inline at message-send time. `id` becomes the row's
    /// id. A send that went while this was in the air has withheld that id, and the file is already
    /// on its way with the message, so a late answer must not put the chip back.
    public func addAttachment(key: String, file: PaiFileUpload, id: String) async -> DraftAttachment? {
        guard !DraftKey.isLocal(key) else { return nil }
        guard let attachment = try? await api.addDraftAttachment(key: key, file: file, id: id) else { return nil }
        if withheldAttachmentIds[key]?.contains(attachment.id) == true { return attachment }
        var entry = draft(for: key)
        entry.attachments.append(attachment)
        drafts[key] = entry
        return attachment
    }

    /// Removes an attachment from this draft — the local copy first, so the chip disappears at
    /// once rather than waiting on `syncFromServer`'s own poll, then the server's.
    public func removeAttachment(key: String, attachmentId: String) async {
        var entry = draft(for: key)
        entry.attachments.removeAll { $0.id == attachmentId }
        drafts[key] = entry
        guard !DraftKey.isLocal(key) else { return }
        _ = try? await api.removeDraftAttachment(key: key, attachmentId: attachmentId)
    }

    /// Takes attachments out of the composer because a message now carries them: dropped from the
    /// local draft at once, and ignored by ``syncFromServer()`` until ``releaseAttachments(key:ids:)``.
    /// Nothing is deleted on the server — the send request claims the rows.
    public func withholdAttachments(key: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        withheldAttachmentIds[key, default: []].formUnion(ids)
        guard var entry = drafts[key] else { return }
        let kept = entry.attachments.filter { !ids.contains($0.id) }
        guard kept.count != entry.attachments.count else { return }
        entry.attachments = kept
        drafts[key] = entry
    }

    /// Hands attachments back to the composer after the message that carried them was abandoned
    /// unsent (discarded, refused, pulled back); the rows are still on the server, so the next
    /// poll lists them again.
    public func releaseAttachments(key: String, ids: [String]) {
        guard var held = withheldAttachmentIds[key] else { return }
        held.subtract(ids)
        withheldAttachmentIds[key] = held.isEmpty ? nil : held
    }

    // MARK: - Clearing

    /// Discards a draft, locally and on the server — implemented server-side as an empty text
    /// plus a version bump plus attachment cleanup; the row itself is never removed. Local state
    /// clears immediately; the network call is serialized against whatever else is already
    /// touching this key exactly like any other op (``requestOp(_:_:)``), so a write already in
    /// flight for older text cannot land after this discard and put it back.
    ///
    /// **The entry itself is kept, only emptied — never set to `nil`.** Dropping it entirely would
    /// drop `knownVersion` with it, and a poll response that predates the discard (still reporting
    /// the pre-discard row) would then read as newer than nothing and put the discarded text
    /// straight back. `performOp`'s own `.delete` case updates `knownVersion` again once the
    /// discard's own response names the version it actually produced, closing the gap for the
    /// interval before that response lands too.
    ///
    /// **When a caller should call this:** after its own send request resolves successfully —
    /// never optimistically, and never gated on the transcript confirming the send. A failed send
    /// must leave the draft in place so nothing typed is lost, which is why this is a call the
    /// composer makes itself rather than something triggered by send-tracking here.
    public func clearDraft(key: String) {
        pendingDebounce[key]?.cancel()
        pendingDebounce[key] = nil
        var entry = draft(for: key)
        entry.text = ""
        entry.attachments = []
        drafts[key] = entry
        unwrittenFields[key] = nil
        awaitingListing.remove(key)
        localRevision[key, default: 0] += 1
        retryAttempt[key] = nil
        diagnosticsLog?.log(.info, .drafts, "clear key=\(key)")
        guard !DraftKey.isLocal(key) else { return }
        Task { await self.requestOp(key, .delete) }
    }

    /// Empties the box a message was just sent from, without writing that to the server: the
    /// send itself clears the row, and only while the row is still the one this composer knew
    /// (`OutboxEntry.draftVersion`), so text another device put there since is not replaced by
    /// this device's empty box. A write already in the air carries an earlier state of the
    /// message and may land after the send consumed the row; the emptied box is written once it
    /// settles, so that text does not stay behind for the other devices.
    public func clearAfterSend(key: String) {
        pendingDebounce[key]?.cancel()
        pendingDebounce[key] = nil
        retryAttempt[key] = nil
        awaitingListing.remove(key)
        var entry = draft(for: key)
        entry.text = ""
        entry.previousText = nil
        drafts[key] = entry
        localRevision[key, default: 0] += 1
        if currentOp[key] != nil {
            unwrittenFields[key] = [.text]
            queuedOp[key] = .write
        } else {
            unwrittenFields[key] = nil
        }
        diagnosticsLog?.log(.info, .drafts, "sent key=\(key)")
    }

    // MARK: - Flush (debounced write)

    private func scheduleFlush(_ key: String, since before: DraftEntry) {
        guard !DraftKey.isLocal(key) else { return }
        let changed = DraftField.changed(from: before, to: draft(for: key))
        guard !changed.isEmpty else { return }
        unwrittenFields[key, default: []].formUnion(changed)
        localRevision[key, default: 0] += 1
        retryAttempt[key] = nil
        pendingDebounce[key]?.cancel()
        pendingDebounce[key] = Task { [weak self, scheduler] in
            try? await scheduler.sleep(seconds: Self.flushDebounceSeconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingDebounce[key] = nil
            await self.requestOp(key, .write)
        }
    }

    /// How long a failed flush waits before retrying, doubling per consecutive failure up to a
    /// cap — frequent enough that one dropped request heals within a few seconds, capped low
    /// enough that a genuinely offline device is not hammering the server for the rest of a call.
    public static let retryBaseSeconds: TimeInterval = 2
    public static let retryMaxSeconds: TimeInterval = 30

    /// Writes a draft's unwritten changes to the server right now, waiting for it (and any op
    /// already in flight ahead of it) to fully land; an entry with none sends nothing. Public because the composer must call this
    /// directly — not through the debounce — when it is about to disappear, so leaving a session
    /// cannot strand an edit inside the debounce window.
    public func flush(key: String) async {
        guard !DraftKey.isLocal(key) else { return }
        pendingDebounce[key]?.cancel()
        pendingDebounce[key] = nil
        guard drafts[key] != nil else { return }
        await requestOp(key, .write)
    }

    /// The one place anything asks the server to change a key — a write or a discard. At most one
    /// request in flight per key: a request arriving while one is already running is coalesced
    /// into ``queuedOp``, never fired as a second, concurrent request. This is the fix for the fix
    /// the web's own investigation named: the previous shape awaited the in-flight request and
    /// *then* started its own, which fans every debounce that expired while a slow write was on
    /// the wire out into its own follow-up PUT — up to one per keystroke. Coalescing collapses any
    /// number of those into exactly one further write, carrying whatever text is current the
    /// moment the in-flight request actually finishes.
    private func requestOp(_ key: String, _ op: PendingOp) async {
        guard !DraftKey.isLocal(key) else { return }
        if currentOp[key] != nil {
            queuedOp[key] = op
            await currentOp[key]?.value
            return
        }
        await performOp(key, op)
    }

    /// Runs one op to completion, then — if something was requested while it ran — runs that one
    /// too, awaited from inside this same task so a caller of ``requestOp(_:_:)`` that finds
    /// `currentOp` already set and simply awaits it is guaranteed the *whole* coalesced chain has
    /// drained by the time that await returns, not just the request it happened to observe.
    private func performOp(_ key: String, _ op: PendingOp) async {
        let log = diagnosticsLog
        let task = Task { [weak self] in
            guard let self else { return }
            switch op {
            case .write:
                await self.performWrite(key: key, log: log)
            case .delete:
                if let result = try? await self.api.deleteDraft(key: key) {
                    self.applyDiscardResult(key: key, result: result)
                    log?.log(.info, .drafts, "delete key=\(key) version=\(String(describing: result.version)) done")
                }
            }
            self.currentOp[key] = nil
            if let next = self.queuedOp[key] {
                self.queuedOp[key] = nil
                await self.performOp(key, next)
            }
        }
        currentOp[key] = task
        await task.value
    }

    private func performWrite(key: String, log: VoiceDiagnosticsLog?) async {
        // Nothing unwritten: the entry holds what the server last said, or something older, and
        // writing it back only ever replaces newer text with it.
        guard let entry = drafts[key], unwrittenFields[key]?.isEmpty == false else { return }
        guard hasListed else {
            awaitingListing.insert(key)
            return
        }
        let revisionAtWrite = localRevision[key]
        do {
            let result = try await api.putDraft(
                key: key, text: entry.text, deviceId: deviceId, sessionType: entry.sessionType,
                workingDir: entry.workingDir, model: entry.model, thinking: entry.thinking,
                noMemory: entry.noMemory
            )
            guard var current = drafts[key] else { return }
            current.knownVersion = result.version
            current.previousText = result.previousText
            drafts[key] = current
            // Carried, unless something changed while it was in the air; which fields that touched
            // is not known apart, so the record is kept whole then.
            if localRevision[key] == revisionAtWrite { unwrittenFields[key] = nil }
            retryAttempt[key] = nil
            log?.log(.info, .drafts, "flush key=\(key) chars=\(entry.text.count) version=\(result.version) done")
        } catch {
            // Keep the local copy and retry — scheduled into `pendingDebounce`, the same slot a
            // fresh edit's own debounce uses, so `syncFromServer` treats a write still waiting to
            // retry exactly like one still waiting to happen for the first time: strictly newer
            // than anything the server can report, never overwritten by an older row landing in
            // between. A queued coalesced follow-up (if any) is dropped in favour of the retry,
            // which will pick up whatever text is current when it fires anyway.
            queuedOp[key] = nil
            log?.log(.warning, .drafts, "flush key=\(key) failed, retrying: \(error)")
            scheduleRetry(key)
        }
    }

    private func scheduleRetry(_ key: String) {
        let attempt = (retryAttempt[key] ?? 0) + 1
        retryAttempt[key] = attempt
        let delay = min(Self.retryBaseSeconds * pow(2, Double(attempt - 1)), Self.retryMaxSeconds)
        pendingDebounce[key]?.cancel()
        pendingDebounce[key] = Task { [weak self, scheduler] in
            try? await scheduler.sleep(seconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingDebounce[key] = nil
            await self.requestOp(key, .write)
        }
    }

    // MARK: - Reconciling with the server

    /// Adopts every server row this device does not have a fresher local claim on. A key absent
    /// from the response is never touched — the row is never actually gone (a discard writes
    /// empty text, it never deletes), so a poll answering without a key it used to list means
    /// nothing about that key at all, never "delete the local copy".
    public func syncFromServer() async {
        let revisionsAtRequest = localRevision
        let requestedAt = clock.now()
        let remote: [Draft]
        do {
            remote = try await api.getDrafts()
        } catch {
            return
        }

        // A local key is never a server row; one listed anyway is not this device's to adopt.
        for row in remote where !DraftKey.isLocal(row.key) {
            // A key with an unwritten local edit, a write or delete already on the wire, or any
            // local change since this request left, is newer than anything this response can
            // report — adopting it would put back text the device already replaced. Comparing
            // `localRevision` against the snapshot taken before the request left is what catches
            // "changed while the request was in flight" even once the write that caused it has
            // itself already finished.
            let unwritten = unwrittenFields[row.key] ?? []
            let isClean =
                unwritten.isEmpty && pendingDebounce[row.key] == nil && currentOp[row.key] == nil
                && localRevision[row.key] == revisionsAtRequest[row.key]
            var entry = drafts[row.key] ?? .empty
            var changed = false
            // `row.version <= knownVersion` is ignored regardless of content — this is the rule
            // that replaces comparing `updated_at` for inequality, and it is what makes a response
            // that predates this device's own flush harmless however it is ordered on arrival.
            if row.version > (entry.knownVersion ?? -1) {
                var adopted = entry
                adopted.text = row.text
                adopted.sessionType = row.sessionType
                adopted.workingDir = row.workingDir
                adopted.model = row.model
                adopted.thinking = row.thinking
                adopted.noMemory = row.noMemory
                adopted.knownVersion = row.version
                if isClean {
                    entry = adopted
                    changed = true
                } else if currentOp[row.key] == nil, !unwritten.isEmpty {
                    // Merged field by field: what this device changed stays, everything else is
                    // the row's, so an untouched field never carries a stale value back over a
                    // newer one. An emptied text is no edit worth keeping over text this device
                    // has not seen.
                    let kept = unwritten.filter { !($0 == .text && entry.text.isEmpty && !row.text.isEmpty) }
                    var merged = adopted
                    for field in kept { field.copy(from: entry, into: &merged) }
                    let differing = kept.filter { !$0.same(merged, adopted) }
                    entry = merged
                    changed = true
                    if differing.isEmpty {
                        unwrittenFields[row.key] = nil
                        pendingDebounce[row.key]?.cancel()
                        pendingDebounce[row.key] = nil
                        retryAttempt[row.key] = nil
                        awaitingListing.remove(row.key)
                    } else {
                        unwrittenFields[row.key] = differing
                    }
                }
            }
            // Attachments are a separate resource with set semantics, adopted always and
            // independently of the text-ordering rule above — they already have the right model
            // (tombstones on removal), and another device's just-added file should appear even
            // while this device's own text edit is still in flight.
            let withheld = withheldAttachmentIds[row.key] ?? []
            // `unclaimed` is the server saying a send named the row and could not move it: the
            // one state that must stay visible after a send.
            let listed = row.attachments.filter { !withheld.contains($0.id) || $0.state == "unclaimed" }
            if entry.attachments != listed {
                entry.attachments = listed
                changed = true
            }
            // `previousText` is informational, like attachments — adopted whenever the row is not
            // older than what this device knows, independent of whether the text itself is dirty.
            // A dirty entry's `knownVersion` is exactly "the version this device last reconciled
            // with", so a row from another device sitting ahead of that is still newer information
            // about what to offer as "Restore earlier version", even while this device's own edit
            // is what is actually on screen.
            if row.version >= (entry.knownVersion ?? -1), entry.previousText != row.previousText {
                entry.previousText = row.previousText
                changed = true
            }
            if changed {
                drafts[row.key] = entry
            }
            serverAttachmentsObserved?(row.key, Set(row.attachments.map(\.id)), requestedAt)
        }
        hasListed = true
        let waiting = awaitingListing
        awaitingListing = []
        for key in waiting { Task { await self.requestOp(key, .write) } }
    }

    /// After a successful send has cleared this draft server-side, records the version that clear
    /// produced — so this device's own next poll is a no-op rather than a wasted round trip. A
    /// pure optimisation: skipping this call changes nothing but the timing of the next
    /// reconciliation, so it is guarded conservatively — only when the key is still exactly the
    /// empty, untouched state the send itself left it in — rather than risk clobbering a fresh
    /// edit typed into the same key before the send's own response arrived.
    public func recordVersionAfterSend(key: String, version: Int?) {
        guard let version else { return }
        guard pendingDebounce[key] == nil, currentOp[key] == nil else { return }
        guard var entry = drafts[key], entry.text.isEmpty, (entry.knownVersion ?? -1) < version else { return }
        entry.knownVersion = version
        drafts[key] = entry
    }
}
