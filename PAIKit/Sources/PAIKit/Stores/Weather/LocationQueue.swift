import Foundation

/// The points waiting to reach the server, kept in a JSON-lines file so a relaunch, a locked
/// phone or a lost connection loses none of them.
///
/// Plain fixes are the only points that may be dropped, oldest first, once the queue is full: a
/// visit or a region event is rare and carries meaning, so those are kept even past the limit.
public actor LocationQueue {
    public static let capacity = 5000

    private let fileURL: URL
    private var points: [LocationPoint]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        points = Self.read(fileURL)
    }

    public var count: Int { points.count }

    public var all: [LocationPoint] { points }

    public func append(_ point: LocationPoint) {
        points.append(point)
        if trim() {
            persist()
        } else {
            appendToFile(point)
        }
    }

    /// The oldest points, up to `limit`, still in the queue until ``remove(first:)`` says they arrived.
    public func batch(limit: Int = LocationPointsRequest.maxPoints) -> [LocationPoint] {
        Array(points.prefix(limit))
    }

    public func remove(first count: Int) {
        points.removeFirst(min(count, points.count))
        persist()
    }

    /// Whether anything was dropped, which makes the file out of date as a whole.
    private func trim() -> Bool {
        var dropped = false
        while points.count > Self.capacity {
            guard let index = points.firstIndex(where: { $0.kind.isDroppable }) else { return dropped }
            points.remove(at: index)
            dropped = true
        }
        return dropped
    }

    /// One more line at the end of the file; a file that does not exist yet is written whole.
    private func appendToFile(_ point: LocationPoint) {
        guard FileManager.default.fileExists(atPath: fileURL.path), let handle = try? FileHandle(forWritingTo: fileURL),
            var line = try? Self.makeEncoder().encode(point)
        else {
            persist()
            return
        }
        defer { try? handle.close() }
        line.append(0x0A)
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// One per use: a `JSONEncoder` is not `Sendable` on every platform, so none is shared.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func persist() {
        let encoder = Self.makeEncoder()
        var data = Data()
        for point in points {
            guard let line = try? encoder.encode(point) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
            // A background relaunch on a phone that has not been unlocked since boot appends too.
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try? data.write(to: fileURL, options: .atomic)
        #endif
    }

    private static func read(_ url: URL) -> [LocationPoint] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(LocationPoint.self, from: Data($0)) }
    }
}
