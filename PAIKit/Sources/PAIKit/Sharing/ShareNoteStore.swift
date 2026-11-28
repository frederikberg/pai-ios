import Foundation
import Observation

/// What the share sheet's "Note" needs from the backend; `PaiApiClient` conforms structurally.
public protocol ShareNoteBackend: Sendable {
    func getNoteContainers() async throws -> [NoteContainer]
    func uploadNoteAttachment(containerId: String, filename: String, mimeType: String, data: Data) async throws
        -> NoteAttachmentUploaded
    func createNote(name: String, summary: String?, body: String?, containerId: String?) async throws -> NoteDetail
}

extension PaiApiClient: ShareNoteBackend {}

/// Where the share sheet can put what was shared.
public enum ShareTarget: String, CaseIterable, Sendable, Identifiable {
    case todo, note, session

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .todo: "Todo"
        case .note: "Note"
        case .session: "Session"
        }
    }

    /// The targets this person has, in the order shown. Until the server has said who they are,
    /// only the session is offered: it is the one every signed-in person has.
    public static func offered(to capabilities: Capabilities) -> [ShareTarget] {
        allCases.filter { target in
            switch target {
            case .todo: capabilities.canOpenTodos
            case .note: capabilities.canOpenNotes
            case .session: true
            }
        }
    }
}

/// "Note" in the share sheet: what was shared becomes a new note. Shared text is its body, a
/// link follows as a line of its own, and photos and files are placed in the notes' attachments
/// and embedded at the bottom.
///
/// Nothing is kept on disk. A failed attempt leaves the name and everything shared in the sheet;
/// trying again uploads only the files that did not arrive before.
@Observable
@MainActor
public final class ShareNoteStore {

    public enum Phase: Equatable, Sendable {
        case editing
        case sending
        case added(name: String)
        case failed(message: String)
    }

    /// The note's name, prefilled from what was shared.
    public var name: String
    public let text: String?
    public let link: String?
    public let files: [ShareItem]
    public private(set) var phase: Phase = .editing

    @ObservationIgnored private var backend: (any ShareNoteBackend)?
    /// Where each file landed, by the file's id.
    @ObservationIgnored private var embedded: [String: String] = [:]

    public init(sharedText: String?, link: String?, files: [ShareItem] = []) {
        text = sharedText.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.link = link
        self.files = files
        name = Self.suggestedName(text: text, link: link, files: files)
    }

    /// Connect to the server. Called by the view that is on screen.
    public func start(_ backend: any ShareNoteBackend) {
        self.backend = backend
    }

    /// The name a note gets before the person types one: the text's first line, cut at a word
    /// within 80 characters, else the link's host, else the first file's name without its ending.
    static func suggestedName(text: String?, link: String?, files: [ShareItem]) -> String {
        if let line = text?.split(separator: "\n").first.map({ $0.trimmingCharacters(in: .whitespaces) }), !line.isEmpty
        {
            guard line.count > 80 else { return line }
            let head = String(line.prefix(80))
            let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
            return cut + "\u{2026}"
        }
        if let link, let host = URL(string: link)?.host { return host }
        if let file = files.first {
            let base = (file.name as NSString).deletingPathExtension
            return base.isEmpty ? file.name : base
        }
        return ""
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var canAdd: Bool {
        switch phase {
        case .editing, .failed: return !trimmedName.isEmpty
        case .sending, .added: return false
        }
    }

    public func add() async {
        guard canAdd, let backend else { return }
        phase = .sending
        do {
            var containerId: String?
            if !files.isEmpty {
                let containers = try await backend.getNoteContainers()
                guard let home = containers.first(where: { $0.isDefault && $0.enabled }) else {
                    phase = .failed(message: "Notes have no default folder, so a file has nowhere to go.")
                    return
                }
                containerId = home.id
                for file in files where embedded[file.id] == nil {
                    let prepare = file.prepare
                    let upload = try await Task.detached(operation: { try prepare() }).value
                    let placed = try await backend.uploadNoteAttachment(
                        containerId: home.id, filename: upload.filename, mimeType: upload.mimeType, data: upload.data)
                    embedded[file.id] = placed.relPath
                }
            }
            let made = try await backend.createNote(
                name: trimmedName, summary: nil, body: body, containerId: containerId)
            phase = .added(name: made.name)
        } catch {
            phase = .failed(message: Self.message(for: error))
        }
    }

    /// The note's text: what was shared, the link, then one embed per file.
    var body: String {
        var parts: [String] = []
        if let text { parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let link, text?.contains(link) != true { parts.append(link) }
        let embeds = files.compactMap { embedded[$0.id] }.map { "![[\($0)]]" }
        if !embeds.isEmpty { parts.append(embeds.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    private static func message(for error: Error) -> String {
        guard let paiError = error as? PaiError else { return error.localizedDescription }
        if paiError.isAuthenticationFailure { return "PAI refused the sign-in. Open the app and sign in again." }
        return paiError.userMessage
    }
}
