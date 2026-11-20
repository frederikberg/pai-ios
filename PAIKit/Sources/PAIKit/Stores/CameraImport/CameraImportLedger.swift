import Foundation

/// The camera files already added to Photos. Kept by the app because add-only access to the
/// photo library cannot read back what is in it.
///
/// A JSON array of ``CameraImportFile/ledgerKey`` values, rewritten whole after every imported
/// file, so a run cut short keeps what it finished.
public struct CameraImportLedger: Sendable {
    public let fileURL: URL
    public private(set) var keys: Set<String>

    /// Reads the ledger; a missing or unreadable file is an empty one.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        keys = Set(data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    public mutating func record(_ file: CameraImportFile) throws {
        keys.insert(file.ledgerKey)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(keys.sorted()).write(to: fileURL, options: .atomic)
    }
}
