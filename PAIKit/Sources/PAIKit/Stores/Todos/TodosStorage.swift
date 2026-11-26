import Foundation

/// A capture whose words the parser has not read yet: queued without a connection, read by
/// `POST /parse` once there is one, and only then made into its `todo.create`.
public struct TodosCapture: Codable, Equatable, Sendable {
    public let text: String
    /// What did not fit in a title: the lines after the first, or the whole text when its first
    /// line was too long.
    public let body: String?
    /// The id the created todo gets, fixed at capture so the queued row and the created one are
    /// the same todo.
    public let todoId: String
    public let list: String?
    public let links: [TodoLinkSpec]
    /// The person's day when the words were spoken, when their preferences were known then. The
    /// parser reads "tomorrow" against the day it runs on, so a capture that waited past a day
    /// boundary (or whose day is unknown) is created with its words as the title instead.
    public let day: String?

    enum CodingKeys: String, CodingKey {
        case text, body, list, links, day
        case todoId = "todo_id"
    }

    public init(
        text: String, body: String? = nil, todoId: String, list: String?, links: [TodoLinkSpec], day: String?
    ) {
        self.text = text
        self.body = body
        self.todoId = todoId
        self.list = list
        self.links = links
        self.day = day
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        todoId = try container.decode(String.self, forKey: .todoId)
        list = try container.decodeIfPresent(String.self, forKey: .list)
        links = try container.decodeIfPresent([TodoLinkSpec].self, forKey: .links) ?? []
        day = try container.decodeIfPresent(String.self, forKey: .day)
    }
}

/// One change waiting to be (re)sent: the web outbox's `QueuedChange`, plus the door it came
/// through, who queued it, and a capture still to be read. `change_id` makes every resend
/// idempotent on the server.
public struct TodosQueuedChange: Codable, Equatable, Sendable, Identifiable {
    public let changeId: String
    public let summary: String?
    /// Empty only while `capture` waits to be read.
    public var ops: [TodoOp]
    public var capture: TodosCapture?
    /// `X-Todos-Source` as it was when the change was made; a value this build does not know
    /// is sent as it is.
    public let source: String
    /// Who was signed in when it was queued; a change goes out only as that person.
    public let principal: String?
    /// ISO-8601, UTC.
    public let queuedAt: String

    public var id: String { changeId }

    public init(
        changeId: String, summary: String?, ops: [TodoOp], capture: TodosCapture? = nil, source: String,
        principal: String?, queuedAt: String
    ) {
        self.changeId = changeId
        self.summary = summary
        self.ops = ops
        self.capture = capture
        self.source = source
        self.principal = principal
        self.queuedAt = queuedAt
    }

    enum CodingKeys: String, CodingKey {
        case summary, ops, capture, source, principal
        case changeId = "change_id"
        case queuedAt = "queued_at"
    }
}

/// A change the server refused, kept so what was typed or spoken is never lost to a toast.
public struct TodosRefusedChange: Codable, Equatable, Sendable, Identifiable {
    public let changeId: String
    /// The titles it would have created, or the captured words.
    public let text: String
    public let reason: String
    public let refusedAt: String

    public var id: String { changeId }

    enum CodingKeys: String, CodingKey {
        case text, reason
        case changeId = "change_id"
        case refusedAt = "refused_at"
    }
}

/// What the server last said: what a cold start without a network shows.
public struct TodosCache: Codable, Equatable, Sendable {
    public var me: TodosMeAnswer?
    public var today: TodosTodayAnswer?
    /// Every todo the server has answered with and that has not been read back as closed or gone
    /// since, by id: the open todos after a full read, plus whatever later answers carried.
    public var todos: [String: Todo]

    public init(me: TodosMeAnswer? = nil, today: TodosTodayAnswer? = nil, todos: [String: Todo] = [:]) {
        self.me = me
        self.today = today
        self.todos = todos
    }
}

/// Where the Todos engine keeps the queue and the cache. The queue is the only copy of what was
/// typed, so nothing that drops the cache touches it.
public protocol TodosStorage: Sendable {
    func loadQueue() -> [TodosQueuedChange]
    /// False when the queue did not reach the disk.
    @discardableResult
    func saveQueue(_ queue: [TodosQueuedChange]) -> Bool
    func loadRefused() -> [TodosRefusedChange]
    func saveRefused(_ refused: [TodosRefusedChange])
    func loadCache() -> TodosCache?
    /// Nil removes it.
    func saveCache(_ cache: TodosCache?)
}

/// `outbox.json` (`{"v": 1, "changes": [...]}`, the web's record) and `refused.json` under the
/// root, `cache.json` under a cache directory kept out of the backup. Each is replaced whole by
/// an atomic rename. A queued change this build cannot read is moved to `unreadable/` as it was,
/// never dropped and never overwritten by the next save.
public struct FileTodosStorage: TodosStorage {
    public let rootURL: URL
    public let cacheURL: URL

    static let recordVersion = 1

    private var fileManager: FileManager { .default }

    public init(rootURL: URL, cacheDirectory: URL) {
        self.rootURL = rootURL
        self.cacheURL = cacheDirectory.appendingPathComponent("cache.json")
        for directory in [rootURL, unreadableDirectory, cacheDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private var outboxURL: URL { rootURL.appendingPathComponent("outbox.json") }
    private var refusedURL: URL { rootURL.appendingPathComponent("refused.json") }
    private var unreadableDirectory: URL { rootURL.appendingPathComponent("unreadable", isDirectory: true) }

    private struct Record: Codable {
        let v: Int
        let changes: [PaiJSONValue]
    }

    public func loadQueue() -> [TodosQueuedChange] {
        guard let data = try? Data(contentsOf: outboxURL) else { return [] }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.v == Self.recordVersion else {
            setAside(data)
            try? fileManager.removeItem(at: outboxURL)
            return []
        }
        var queue: [TodosQueuedChange] = []
        var unreadable: [PaiJSONValue] = []
        for entry in record.changes {
            if let data = try? JSONEncoder().encode(entry),
                let change = try? JSONDecoder().decode(TodosQueuedChange.self, from: data)
            {
                queue.append(change)
            } else {
                unreadable.append(entry)
            }
        }
        if !unreadable.isEmpty, let data = try? JSONEncoder().encode(unreadable) {
            setAside(data)
            saveQueue(queue)
        }
        return queue
    }

    @discardableResult
    public func saveQueue(_ queue: [TodosQueuedChange]) -> Bool {
        guard !queue.isEmpty else {
            try? fileManager.removeItem(at: outboxURL)
            return !fileManager.fileExists(atPath: outboxURL.path)
        }
        let entries = queue.compactMap { change -> PaiJSONValue? in
            guard let data = try? JSONEncoder().encode(change) else { return nil }
            return try? JSONDecoder().decode(PaiJSONValue.self, from: data)
        }
        guard entries.count == queue.count else { return false }
        return NotesFileIO.write(Record(v: Self.recordVersion, changes: entries), to: outboxURL)
    }

    public func loadRefused() -> [TodosRefusedChange] {
        NotesFileIO.read([TodosRefusedChange].self, from: refusedURL) ?? []
    }

    public func saveRefused(_ refused: [TodosRefusedChange]) {
        if refused.isEmpty {
            try? fileManager.removeItem(at: refusedURL)
        } else {
            NotesFileIO.write(refused, to: refusedURL)
        }
    }

    public func loadCache() -> TodosCache? {
        NotesFileIO.read(TodosCache.self, from: cacheURL)
    }

    public func saveCache(_ cache: TodosCache?) {
        if let cache {
            NotesFileIO.write(cache, to: cacheURL)
        } else {
            try? fileManager.removeItem(at: cacheURL)
        }
    }

    private func setAside(_ data: Data) {
        let name = "outbox-\(IsoTimestamp.utcString(from: Date()))-\(UUID().uuidString).json"
            .replacingOccurrences(of: ":", with: "-")
        try? data.write(to: unreadableDirectory.appendingPathComponent(name), options: .atomic)
    }
}

/// The queue and cache in memory, for tests of the store's rules. A test that proves something
/// survives a restart builds a second store over the same instance.
public final class InMemoryTodosStorage: TodosStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [TodosQueuedChange] = []
    private var refused: [TodosRefusedChange] = []
    private var cache: TodosCache?

    public init() {}

    public func loadQueue() -> [TodosQueuedChange] { lock.withLock { queue } }
    @discardableResult
    public func saveQueue(_ queue: [TodosQueuedChange]) -> Bool {
        lock.withLock { self.queue = queue }
        return true
    }
    public func loadRefused() -> [TodosRefusedChange] { lock.withLock { refused } }
    public func saveRefused(_ refused: [TodosRefusedChange]) { lock.withLock { self.refused = refused } }
    public func loadCache() -> TodosCache? { lock.withLock { cache } }
    public func saveCache(_ cache: TodosCache?) { lock.withLock { self.cache = cache } }
}
