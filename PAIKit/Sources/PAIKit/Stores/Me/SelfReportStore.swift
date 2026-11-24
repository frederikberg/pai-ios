import Foundation
import Observation

public protocol SelfReportApiClient: Sendable {
    func getMeOverview(days: Int, end: String?) async throws -> MeOverview
    func getMeDay(date: String) async throws -> MeDay
    func getSelfReports(before: String?, limit: Int, feel: String?, privateOnly: Bool) async throws -> SelfReportPage
    func createSelfReport(_ body: SelfReportCreateBody) async throws -> SelfReport
    func patchSelfReport(id: String, _ body: SelfReportPatchBody) async throws -> SelfReport
    func deleteSelfReport(id: String) async throws
    func restoreSelfReport(id: String) async throws
}

extension PaiApiClient: SelfReportApiClient {}

/// What the composer holds between openings: text, a face, Private and the moment the entry is
/// about (nil = now, filled in when it is sent).
public struct SelfReportDraft: Codable, Sendable, Equatable {
    public var text: String
    public var feel: String?
    public var isPrivate: Bool
    public var at: Date?

    public init(text: String = "", feel: String? = nil, isPrivate: Bool = false, at: Date? = nil) {
        self.text = text
        self.feel = feel
        self.isPrivate = isPrivate
        self.at = at
    }

    /// An entry needs words or a face; nothing else is required.
    public var canSend: Bool { feel != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether a half-written entry exists, which the launcher tile marks with a dot.
    public var isEmpty: Bool { !canSend && !isPrivate && at == nil }
}

/// An entry written on this phone and not yet acknowledged by the server. Its `id` is the one the
/// POST carries, so a retry after a lost answer cannot make a second row.
public struct PendingSelfReport: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String?
    public let feel: String?
    public let isPrivate: Bool
    public let at: String
    /// Set once the server refused the entry for good; the diary says so and offers to put it
    /// back in the composer instead of retrying.
    public var refusal: String?

    public init(id: String, text: String?, feel: String?, isPrivate: Bool, at: String, refusal: String? = nil) {
        self.id = id
        self.text = text
        self.feel = feel
        self.isPrivate = isPrivate
        self.at = at
        self.refusal = refusal
    }

    var body: SelfReportCreateBody {
        SelfReportCreateBody(id: id, text: text, feel: feel, isPrivate: isPrivate, at: at)
    }

    /// How the diary draws it until the server has it.
    var asReport: SelfReport {
        SelfReport(
            id: id, at: at, text: text, feel: feel.flatMap { SelfReportFeel.knownValues[$0] },
            isPrivate: isPrivate, source: .ios)
    }
}

/// One row of the diary list: a stored entry, or one still waiting to reach the server.
public struct MeDiaryItem: Equatable, Sendable, Identifiable {
    public let report: SelfReport
    public let waiting: Bool
    public let refusal: String?
    public var id: String { report.id }

    public init(report: SelfReport, waiting: Bool, refusal: String?) {
        self.report = report
        self.waiting = waiting
        self.refusal = refusal
    }
}

/// The diary and the composer's state: entries read from the server, the draft kept on the phone,
/// and the outbox that makes Send succeed locally whether or not the network is there.
///
/// Send hands the entry to the outbox and clears the draft at once; the POST follows when it can.
/// Both the draft and the outbox live in `storage`, so a relaunch finds them as they were.
@MainActor
@Observable
public final class SelfReportStore {
    public static let draftKey = "me-composer"
    public static let outboxKey = "me-outbox"
    public static let pageSize = 50

    public private(set) var entries: [SelfReport] = []
    public private(set) var pending: [PendingSelfReport] = []
    public private(set) var draft = SelfReportDraft()
    public private(set) var isLoading = false
    private var nextBefore: String?
    public var hasMore: Bool { nextBefore != nil }
    public private(set) var errorMessage: String?
    /// Bumped each time an entry reaches the server, so the overview and a day's detail know to read again.
    public private(set) var savedVersion = 0

    public var feelFilter: SelfReportFeel?
    public var privateOnly = false

    private let api: SelfReportApiClient
    private let storage: SettingsKeyValueStore
    private let now: @Sendable () -> Date
    private let makeId: @Sendable () -> String
    private var isFlushing = false
    private var loadedOnce = false

    public init(
        api: SelfReportApiClient, storage: SettingsKeyValueStore, now: @escaping @Sendable () -> Date = { Date() },
        makeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.api = api
        self.storage = storage
        self.now = now
        self.makeId = makeId
        draft = storage.value(forKey: Self.draftKey) ?? SelfReportDraft()
        pending = storage.value(forKey: Self.outboxKey) ?? []
    }

    // MARK: Draft

    public func updateDraft(_ change: (inout SelfReportDraft) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else { return }
        draft = next
        persistDraft()
    }

    public func clearDraft() {
        draft = SelfReportDraft()
        persistDraft()
    }

    private func persistDraft() {
        storage.setValue(draft.isEmpty ? nil : draft, forKey: Self.draftKey)
    }

    // MARK: Sending

    /// Queues the draft as an entry and clears it. Returns false for a draft with neither words
    /// nor a face, which is no entry.
    @discardableResult
    public func send() -> Bool {
        guard draft.canSend else { return false }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let moment = draft.at ?? now()
        let item = PendingSelfReport(
            id: makeId(), text: text.isEmpty ? nil : text, feel: draft.feel, isPrivate: draft.isPrivate,
            at: AlarmTime.wireString(moment))
        pending.append(item)
        persistOutbox()
        clearDraft()
        Task { await flush() }
        return true
    }

    /// Sends what waits, oldest first, stopping at the first failure that a retry could cure.
    public func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while let next = pending.first(where: { $0.refusal == nil }) {
            do {
                let stored = try await api.createSelfReport(next.body)
                pending.removeAll { $0.id == next.id }
                persistOutbox()
                merge(stored)
                savedVersion += 1
            } catch let error as PaiError where error.isPermanentRejection {
                if let index = pending.firstIndex(where: { $0.id == next.id }) {
                    pending[index].refusal = error.userMessage
                    persistOutbox()
                }
            } catch {
                return
            }
        }
    }

    /// Takes a refused entry out of the outbox and back into the composer. Whatever the composer
    /// held is replaced only when it is empty; otherwise the entry's words join the end of it.
    public func putBack(id: String) {
        guard let item = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        persistOutbox()
        updateDraft { draft in
            if draft.isEmpty {
                draft = SelfReportDraft(
                    text: item.text ?? "", feel: item.feel, isPrivate: item.isPrivate,
                    at: IsoTimestamp.date(from: item.at))
            } else if let text = item.text {
                draft.text = draft.text.isEmpty ? text : draft.text + "\n\n" + text
            }
        }
    }

    private func persistOutbox() {
        storage.setValue(pending.isEmpty ? nil : pending, forKey: Self.outboxKey)
    }

    // MARK: Reading

    /// The diary list as drawn: waiting entries beside stored ones, the filters applied.
    public var items: [MeDiaryItem] {
        let storedIds = Set(entries.map(\.id))
        let waiting = pending.filter { !storedIds.contains($0.id) }.map {
            MeDiaryItem(report: $0.asReport, waiting: $0.refusal == nil, refusal: $0.refusal)
        }
        let stored = entries.map { MeDiaryItem(report: $0, waiting: false, refusal: nil) }
        return (waiting + stored).filter { item in
            if let feelFilter, item.report.feel != feelFilter { return false }
            if privateOnly, !item.report.isPrivate { return false }
            return true
        }
    }

    /// Reads the first page again, with the filters as set.
    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.getSelfReports(
                before: nil, limit: Self.pageSize, feel: feelFilter?.wire, privateOnly: privateOnly)
            entries = page.selfReports
            nextBefore = page.nextBefore
            errorMessage = nil
            loadedOnce = true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the diary"
        }
    }

    /// Reads once per opening of the diary rather than on every appearance.
    public func loadIfNeeded() async {
        if !loadedOnce { await reload() }
    }

    public func loadMore() async {
        guard let cursor = nextBefore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.getSelfReports(
                before: cursor, limit: Self.pageSize, feel: feelFilter?.wire, privateOnly: privateOnly)
            let known = Set(entries.map(\.id))
            entries += page.selfReports.filter { !known.contains($0.id) }
            nextBefore = page.nextBefore
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load more"
        }
    }

    /// Puts a row the server answered into the list at its place, replacing an older copy.
    private func merge(_ report: SelfReport) {
        entries.removeAll { $0.id == report.id }
        let date = report.date ?? .distantPast
        let index = entries.firstIndex { ($0.date ?? .distantPast) < date } ?? entries.endIndex
        entries.insert(report, at: index)
    }

    // MARK: Changing an entry

    public func update(id: String, _ patch: SelfReportPatchBody) async -> Bool {
        do {
            merge(try await api.patchSelfReport(id: id, patch))
            errorMessage = nil
            savedVersion += 1
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not save the change"
            return false
        }
    }

    public func setPrivate(id: String, _ isPrivate: Bool) async {
        _ = await update(id: id, SelfReportPatchBody(isPrivate: isPrivate))
    }

    /// Soft delete: the row leaves the list at once and ``restore(_:)`` brings it back.
    public func delete(_ report: SelfReport) async -> Bool {
        let position = entries.firstIndex { $0.id == report.id }
        entries.removeAll { $0.id == report.id }
        do {
            try await api.deleteSelfReport(id: report.id)
            savedVersion += 1
            return true
        } catch {
            if let position { entries.insert(report, at: min(position, entries.count)) }
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not delete the entry"
            return false
        }
    }

    public func restore(_ report: SelfReport) async {
        do {
            try await api.restoreSelfReport(id: report.id)
            merge(report)
            savedVersion += 1
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not restore the entry"
        }
    }

    /// Whether anything waits for the network, which the diary header and tile can mention.
    public var hasWaiting: Bool { pending.contains { $0.refusal == nil } }
}
