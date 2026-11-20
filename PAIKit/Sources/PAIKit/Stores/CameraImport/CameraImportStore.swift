import Foundation
import Observation

/// A folder the app may read while the grant is held. `release` ends the access.
public struct CameraFolderGrant: Sendable {
    public let url: URL
    public let release: @Sendable () -> Void

    public init(url: URL, release: @escaping @Sendable () -> Void) {
        self.url = url
        self.release = release
    }
}

/// How the app reaches the camera's folder: the one it remembers, or one just picked.
@MainActor
public protocol CameraFolderAccess {
    /// The remembered folder with access started, nil when none is remembered or it no longer
    /// resolves (a bookmark onto an external drive may not survive the drive being unplugged).
    func openRemembered() -> CameraFolderGrant?
    /// Starts access to a picked folder and remembers it for the next run.
    func open(picked url: URL) -> CameraFolderGrant
}

/// Where imported files go.
public protocol CameraImportLibrary: Sendable {
    /// Asks for permission to add; false when it is refused.
    func requestAccess() async -> Bool
    /// Adds one file as a new asset under `originalFilename`. `movingFile` lets the library take
    /// the file instead of copying it, for a copy made only for this.
    func add(_ file: URL, kind: CameraImportKind, originalFilename: String, movingFile: Bool) async throws
}

public struct CameraImportProgress: Equatable, Sendable {
    public var done: Int
    public let total: Int
    public var bytesDone: Int64
    public let bytesTotal: Int64
    public var current: String

    /// By bytes, because one video takes longer than a hundred photos.
    public var fraction: Double {
        guard bytesTotal > 0 else { return total > 0 ? Double(done) / Double(total) : 0 }
        return Double(bytesDone) / Double(bytesTotal)
    }
}

public struct CameraImportFailure: Equatable, Sendable, Identifiable {
    public let name: String
    public let reason: String
    public var id: String { name }
}

public struct CameraImportResult: Equatable, Sendable {
    public let folderName: String
    public var imported = 0
    public let alreadyImported: Int
    public let ignored: Int
    public var failures: [CameraImportFailure] = []
    /// Stopped before every file was tried; the rest is imported by the next run.
    public var stopped = false
}

/// The camera import: lists the camera's folder, adds every photo and video not imported before
/// to the photo library one file at a time, and remembers each one added.
///
/// A file Photos cannot take where it lies is copied into `stagingDirectory` and handed over from
/// there. A file that fails is not remembered, so the next run tries it again.
@MainActor
@Observable
public final class CameraImportStore {
    public enum Phase: Equatable, Sendable {
        case idle
        case scanning
        case importing(CameraImportProgress)
        case finished(CameraImportResult)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// Bound to the folder picker: set when there is no remembered folder to read.
    public var isPickingFolder = false

    public var isBusy: Bool {
        switch phase {
        case .scanning, .importing: return true
        case .idle, .finished, .failed: return false
        }
    }

    private let access: CameraFolderAccess
    private let library: CameraImportLibrary
    private var ledger: CameraImportLedger
    private let stagingDirectory: URL
    private let scanner: CameraFolderScanning
    private let emptyRetryDelay: Duration
    private var stopRequested = false

    public static let noPhotosAccessMessage =
        "PAI may not add to Photos. Allow it under Settings, Privacy & Security, Photos."

    public init(
        access: CameraFolderAccess, library: CameraImportLibrary, ledger: CameraImportLedger,
        stagingDirectory: URL, scanner: CameraFolderScanning = CameraFolderScanner(),
        emptyRetryDelay: Duration = .seconds(1)
    ) {
        self.access = access
        self.library = library
        self.ledger = ledger
        self.stagingDirectory = stagingDirectory
        self.scanner = scanner
        self.emptyRetryDelay = emptyRetryDelay
    }

    /// Imports from the remembered folder, or asks for one when there is none or it lists nothing:
    /// an empty listing of a remembered folder is far more often a lost grant than an empty card.
    public func start() async {
        guard !isBusy else { return }
        guard let grant = access.openRemembered() else {
            isPickingFolder = true
            return
        }
        defer { grant.release() }
        phase = .scanning
        guard let files = try? await scan(grant.url), !files.isEmpty else {
            phase = .idle
            isPickingFolder = true
            return
        }
        await run(files, folder: grant.url)
    }

    /// Imports from a folder just picked, and remembers it.
    public func importFrom(picked url: URL) async {
        guard !isBusy else { return }
        let grant = access.open(picked: url)
        defer { grant.release() }
        phase = .scanning
        do {
            let files = try await scan(grant.url)
            await run(files, folder: grant.url)
        } catch {
            phase = .failed("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func pickerFailed(_ error: Error) {
        phase = .failed("Could not open the folder: \(error.localizedDescription)")
    }

    /// Ends the run after the file being added.
    public func stop() {
        stopRequested = true
    }

    /// A first listing of a freshly attached drive can come back empty; one more look settles it.
    private func scan(_ folder: URL) async throws -> [CameraImportFile] {
        let first = try await scanner.files(in: folder)
        guard first.isEmpty else { return first }
        try? await Task.sleep(for: emptyRetryDelay)
        return try await scanner.files(in: folder)
    }

    private func run(_ files: [CameraImportFile], folder: URL) async {
        let plan = CameraImportPlan(files: files, imported: ledger.keys)
        var result = CameraImportResult(
            folderName: folder.lastPathComponent, alreadyImported: plan.alreadyImported, ignored: plan.ignored)
        guard let first = plan.toImport.first else {
            phase = .finished(result)
            return
        }
        guard await library.requestAccess() else {
            phase = .failed(Self.noPhotosAccessMessage)
            return
        }
        stopRequested = false
        var progress = CameraImportProgress(
            done: 0, total: plan.toImport.count, bytesDone: 0,
            bytesTotal: plan.toImport.reduce(0) { $0 + $1.size }, current: first.name)
        for file in plan.toImport {
            if stopRequested {
                result.stopped = true
                break
            }
            progress.current = file.name
            phase = .importing(progress)
            if let reason = await add(file) {
                result.failures.append(CameraImportFailure(name: file.name, reason: reason))
            } else {
                result.imported += 1
                do {
                    try ledger.record(file)
                } catch {
                    result.failures.append(
                        CameraImportFailure(
                            name: file.name,
                            reason: "Added, but not remembered, so the next run adds it again: "
                                + error.localizedDescription))
                }
            }
            progress.done += 1
            progress.bytesDone += file.size
            phase = .importing(progress)
        }
        phase = .finished(result)
    }

    /// Nil when the file was added, else why not.
    private func add(_ file: CameraImportFile) async -> String? {
        guard let kind = file.kind else { return "Not a photo or video" }
        do {
            try await library.add(file.url, kind: kind, originalFilename: file.name, movingFile: false)
            return nil
        } catch {
            do {
                let copy = try await CameraImportStaging.copy(file.url, into: stagingDirectory)
                defer { CameraImportStaging.remove(copy) }
                try await library.add(copy, kind: kind, originalFilename: file.name, movingFile: true)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
}

extension CameraImportStore.Phase {
    /// What the screen reports to the debug bridge.
    public var factName: String {
        switch self {
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .importing: return "importing"
        case .finished(let result):
            return
                "finished imported=\(result.imported) already=\(result.alreadyImported) ignored=\(result.ignored) failed=\(result.failures.count)"
        case .failed: return "failed"
        }
    }
}
