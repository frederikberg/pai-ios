import Foundation

/// Lists every file under a folder.
public protocol CameraFolderScanning: Sendable {
    func files(in folder: URL) async throws -> [CameraImportFile]
}

/// Walks the folder and every folder below it, so the volume root, `DCIM` and the camera's own
/// subfolder all work as the picked folder. Hidden files are skipped, the `._` companions another
/// computer leaves on a FAT card among them.
public struct CameraFolderScanner: CameraFolderScanning {
    public init() {}

    public func files(in folder: URL) async throws -> [CameraImportFile] {
        try Self.list(folder)
    }

    /// Synchronous, because a directory enumerator cannot be iterated from an async context.
    private static func list(_ folder: URL) throws -> [CameraImportFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let errors = FirstError()
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    errors.keep(error)
                    return true
                })
        else { throw CameraImportError.unreadableFolder }
        var files: [CameraImportFile] = []
        while let url = enumerator.nextObject() as? URL {
            guard !url.lastPathComponent.hasPrefix("."),
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            files.append(CameraImportFile(url: url, size: Int64(values.fileSize ?? 0)))
        }
        // An error with nothing listed is the folder itself refusing; one beside listed files is a
        // subfolder that could not be read, and the rest still imports.
        if files.isEmpty, let error = errors.error { throw error }
        return files
    }

    /// Holds what the enumerator's error handler reports. A box rather than a captured `var`, so
    /// the handler compiles whether or not the SDK declares it `@Sendable`; the enumerator calls it
    /// on the iterating thread only.
    private final class FirstError: @unchecked Sendable {
        private(set) var error: Error?
        func keep(_ error: Error) {
            if self.error == nil { self.error = error }
        }
    }
}

public enum CameraImportError: LocalizedError, Equatable {
    case unreadableFolder

    public var errorDescription: String? {
        switch self {
        case .unreadableFolder: return "The folder could not be read."
        }
    }
}

/// A local copy of a camera file, for when Photos cannot take the file where it lies.
enum CameraImportStaging {
    /// Copies the file into a fresh subfolder of `directory` under its own name, so Photos keeps
    /// the name; returns the copy.
    static func copy(_ file: URL, into directory: URL) async throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: file, to: copy)
        } catch {
            remove(copy)
            throw error
        }
        return copy
    }

    /// Removes a copy and its subfolder; a copy Photos already moved away leaves only the folder.
    static func remove(_ copy: URL) {
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
    }
}
