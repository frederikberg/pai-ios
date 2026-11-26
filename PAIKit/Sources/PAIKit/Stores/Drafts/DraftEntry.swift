import Foundation

/// The key under which the not-yet-created session's draft is stored — its text and its launch
/// choices are as much a part of it as an existing session's key is a part of that session.
public enum DraftKey {
    public static let newSession = "new"

    private static let localPrefix = "local:"

    /// A key for a composer that is not a session's: its text lives on this phone only, is saved and
    /// restored like any other draft, and is never sent to the draft routes (which refuse such a
    /// key) nor read back from them. The point is privacy as much as protocol: a diary entry's
    /// words must not be uploaded as a session draft.
    public static func local(_ name: String) -> String { localPrefix + name }

    public static func isLocal(_ key: String) -> Bool { key.hasPrefix(localPrefix) }
}

/// Composer text that has not been sent, plus the launch choices that only mean anything for
/// ``DraftKey/newSession``. Swift port of `pai-cloud/web/src/stores/drafts.ts`'s `DraftEntry`.
///
/// `Codable` for `DraftStore`'s own local persistence, not for the wire — nothing here decodes a
/// server response into this type directly, so there is no shape to keep in step with `Draft`'s
/// own `CodingKeys` and no reason to give this one any.
public struct DraftEntry: Equatable, Sendable, Codable {
    /// The device owns this text — nothing coming from the network may replace it, and nothing
    /// composes it from anything else. A live dictation take writes here too, through the
    /// ordinary setter, exactly like typing.
    public var text: String
    public var sessionType: String?
    public var workingDir: String?
    /// A `claude --model` alias for the next session — only meaningful on ``DraftKey/newSession``,
    /// alongside `sessionType`/`workingDir`. `nil` lets Claude Code pick the plan's own default.
    public var model: String?
    /// A `claude --effort` level for the next session — only meaningful alongside `model` above.
    /// `nil` lets Claude Code pick the plan's own default.
    public var thinking: String?
    /// Whether the next session is a no-memory one — only meaningful on ``DraftKey/newSession``,
    /// independent of the model choice. Optional so an entry persisted before the field existed
    /// still decodes; `nil` reads as off.
    public var noMemory: Bool?
    /// `version` of the server row this entry was last reconciled with — `nil` for a key never
    /// yet written or adopted. The only field ``DraftStore/syncFromServer()`` orders by: a row
    /// whose `version` is not strictly greater than this is never adopted, however different its
    /// text.
    public var knownVersion: Int?
    /// What the row held immediately before the most recent write or discard this device knows
    /// about — the one-level undo the composer's plus menu offers as "Restore earlier version",
    /// shown only when this is non-empty and differs from `text`. Adopted from any row, write or
    /// discard response whose version is not older than `knownVersion`, independent of whether
    /// `text` itself is dirty — it is informational, like `attachments`, never something a local
    /// edit needs to protect.
    public var previousText: String?
    /// Files uploaded onto this draft — by this device or another one, indistinguishably: the
    /// point of uploading on stage rather than at send is composing one message from several
    /// devices at once, so a phone must see what a laptop just added before either sends.
    public var attachments: [DraftAttachment] = []

    public init(
        text: String, sessionType: String?, workingDir: String?, model: String? = nil, thinking: String? = nil,
        noMemory: Bool? = nil, knownVersion: Int? = nil, previousText: String? = nil,
        attachments: [DraftAttachment] = []
    ) {
        self.text = text
        self.sessionType = sessionType
        self.workingDir = workingDir
        self.model = model
        self.thinking = thinking
        self.noMemory = noMemory
        self.knownVersion = knownVersion
        self.previousText = previousText
        self.attachments = attachments
    }

    public static let empty = DraftEntry(text: "", sessionType: nil, workingDir: nil)
}

/// The fields of a draft a client writes, one by one: what ``DraftStore`` records as changed on this
/// device and merges a newer server row by.
public enum DraftField: CaseIterable, Sendable {
    case text, sessionType, workingDir, model, thinking, noMemory

    func same(_ a: DraftEntry, _ b: DraftEntry) -> Bool {
        switch self {
        case .text: a.text == b.text
        case .sessionType: a.sessionType == b.sessionType
        case .workingDir: a.workingDir == b.workingDir
        case .model: a.model == b.model
        case .thinking: a.thinking == b.thinking
        case .noMemory: (a.noMemory ?? false) == (b.noMemory ?? false)
        }
    }

    /// `target` with this field taken from `source`.
    func copy(from source: DraftEntry, into target: inout DraftEntry) {
        switch self {
        case .text: target.text = source.text
        case .sessionType: target.sessionType = source.sessionType
        case .workingDir: target.workingDir = source.workingDir
        case .model: target.model = source.model
        case .thinking: target.thinking = source.thinking
        case .noMemory: target.noMemory = source.noMemory
        }
    }

    /// The fields that differ between two entries.
    static func changed(from a: DraftEntry, to b: DraftEntry) -> Set<DraftField> {
        Set(allCases.filter { !$0.same(a, b) })
    }
}
