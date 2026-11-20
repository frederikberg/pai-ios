import Foundation
import XCTest

@testable import PAIKit

@MainActor
private final class FakeFolderAccess: CameraFolderAccess {
    var remembered: URL?

    func openRemembered() -> CameraFolderGrant? {
        guard let remembered else { return nil }
        return grant(remembered)
    }

    func open(picked url: URL) -> CameraFolderGrant {
        remembered = url
        return grant(url)
    }

    private func grant(_ url: URL) -> CameraFolderGrant {
        CameraFolderGrant(url: url) {}
    }
}

private struct Refused: Error {}

/// A photo library that records what it was given. `refuses` decides per call (file name, whether
/// it was a copy handed over to move); `onAdd` runs before each answer.
private actor FakeLibrary: CameraImportLibrary {
    struct Added: Equatable {
        let url: URL
        let originalFilename: String
        let kind: CameraImportKind
        let movingFile: Bool
        /// Whether the file was still where `url` points when the library was handed it.
        let existed: Bool
    }

    private(set) var added: [Added] = []
    private(set) var accessRequests = 0
    var grantsAccess = true
    var refuses: @Sendable (String, Bool) -> Bool = { _, _ in false }
    var onAdd: (@Sendable () async -> Void)?

    func set(refuses: @escaping @Sendable (String, Bool) -> Bool) { self.refuses = refuses }
    func set(grantsAccess: Bool) { self.grantsAccess = grantsAccess }
    func set(onAdd: @escaping @Sendable () async -> Void) { self.onAdd = onAdd }

    var addedNames: [String] { added.map(\.originalFilename) }

    func requestAccess() async -> Bool {
        accessRequests += 1
        return grantsAccess
    }

    func add(_ file: URL, kind: CameraImportKind, originalFilename: String, movingFile: Bool) async throws {
        await onAdd?()
        if refuses(originalFilename, movingFile) { throw Refused() }
        added.append(
            Added(
                url: file, originalFilename: originalFilename, kind: kind, movingFile: movingFile,
                existed: FileManager.default.fileExists(atPath: file.path)))
    }
}

/// Lists nothing the first time it is asked, then what the real scanner finds.
private final class EmptyOnceScanner: CameraFolderScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func files(in folder: URL) async throws -> [CameraImportFile] {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        return call == 1 ? [] : try await CameraFolderScanner().files(in: folder)
    }
}

/// The import end to end over real files: what a run adds to the library, what it remembers, and
/// what the next run therefore leaves alone.
@MainActor
final class CameraImportTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CameraImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var volume: URL { root.appendingPathComponent("volume", isDirectory: true) }
    private var camera: URL { volume.appendingPathComponent("DCIM/Camera01", isDirectory: true) }
    private var ledgerURL: URL { root.appendingPathComponent("support/imported.json") }
    private var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }

    private func put(_ names: [String], in folder: URL? = nil) throws {
        let folder = folder ?? camera
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            try Data("bytes of \(name)".utf8).write(to: folder.appendingPathComponent(name))
        }
    }

    private func makeStore(
        access: FakeFolderAccess, library: FakeLibrary, scanner: CameraFolderScanning = CameraFolderScanner()
    ) -> CameraImportStore {
        CameraImportStore(
            access: access, library: library, ledger: CameraImportLedger(fileURL: ledgerURL),
            stagingDirectory: staging, scanner: scanner, emptyRetryDelay: .milliseconds(10))
    }

    private func finished(_ store: CameraImportStore, file: StaticString = #filePath, line: UInt = #line)
        -> CameraImportResult?
    {
        guard case .finished(let result) = store.phase else {
            XCTFail("expected a finished run, got \(store.phase)", file: file, line: line)
            return nil
        }
        return result
    }

    func testASecondRunImportsOnlyWhatIsNewAndNeverAProxy() async throws {
        try put([
            "VID_20261120_102000_00_002.mp4", "LRV_20261120_102000_01_002.lrv", "IMG_20261120_101500_00_001.JPG",
            "IMG_20261120_101500_00_001.dng",
        ])
        let access = FakeFolderAccess()
        let library = FakeLibrary()

        // The volume root is picked, the files sit two folders below it.
        await makeStore(access: access, library: library).importFrom(picked: volume)
        let firstNames = await library.addedNames
        XCTAssertEqual(
            Set(firstNames),
            [
                "VID_20261120_102000_00_002.mp4", "IMG_20261120_101500_00_001.JPG",
                "IMG_20261120_101500_00_001.dng",
            ])
        let kinds = await library.added.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .video }.count, 1)

        // A later run, from a fresh store as after a relaunch, through the remembered folder.
        try put(["IMG_20261121_090000_00_003.jpg"])
        let second = makeStore(access: access, library: library)
        await second.start()
        let names = await library.addedNames
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(names.last, "IMG_20261121_090000_00_003.jpg")
        let result = try XCTUnwrap(finished(second))
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.alreadyImported, 3)
        XCTAssertEqual(result.ignored, 1)
    }

    func testTheSameFileReachedByAnotherPathIsNotImportedTwice() async throws {
        try put(["IMG_1.jpg"])
        let access = FakeFolderAccess()
        let library = FakeLibrary()
        await makeStore(access: access, library: library).importFrom(picked: camera)

        // The drive comes back under another mount point, and its root is picked this time.
        let remounted = root.appendingPathComponent("remounted", isDirectory: true)
        try FileManager.default.moveItem(at: volume, to: remounted)
        let second = makeStore(access: access, library: library)
        await second.importFrom(picked: remounted)
        let count = await library.added.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(finished(second)?.alreadyImported, 1)
    }

    func testAFileRefusedWhereItLiesIsHandedOverAsALocalCopy() async throws {
        try put(["VID_1.mp4"])
        let library = FakeLibrary()
        await library.set(refuses: { _, moving in !moving })
        let store = makeStore(access: FakeFolderAccess(), library: library)

        await store.importFrom(picked: camera)

        let added = await library.added
        XCTAssertEqual(added.count, 1)
        let copy = try XCTUnwrap(added.first)
        XCTAssertTrue(copy.movingFile)
        XCTAssertTrue(copy.existed)
        XCTAssertEqual(copy.originalFilename, "VID_1.mp4")
        XCTAssertNotEqual(copy.url.standardizedFileURL, camera.appendingPathComponent("VID_1.mp4").standardizedFileURL)
        XCTAssertEqual(finished(store)?.imported, 1)
        XCTAssertEqual(finished(store)?.failures, [])
        // The copy is gone again, and the camera's file is untouched.
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertEqual(leftovers, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: camera.appendingPathComponent("VID_1.mp4").path))
    }

    func testAFailedFileIsReportedAndTriedAgainNextRun() async throws {
        try put(["IMG_1.jpg", "IMG_2.jpg"])
        let access = FakeFolderAccess()
        let library = FakeLibrary()
        await library.set(refuses: { name, _ in name == "IMG_2.jpg" })

        let first = makeStore(access: access, library: library)
        await first.importFrom(picked: camera)
        let result = try XCTUnwrap(finished(first))
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.failures.map(\.name), ["IMG_2.jpg"])
        XCTAssertFalse(result.failures[0].reason.isEmpty)

        await library.set(refuses: { _, _ in false })
        let second = makeStore(access: access, library: library)
        await second.start()
        let names = await library.addedNames
        XCTAssertEqual(names, ["IMG_1.jpg", "IMG_2.jpg"])
        XCTAssertEqual(finished(second)?.imported, 1)
    }

    func testARefusedPhotosPermissionAddsAndRemembersNothing() async throws {
        try put(["IMG_1.jpg"])
        let access = FakeFolderAccess()
        let library = FakeLibrary()
        await library.set(grantsAccess: false)

        let store = makeStore(access: access, library: library)
        await store.importFrom(picked: camera)
        XCTAssertEqual(store.phase, .failed(CameraImportStore.noPhotosAccessMessage))
        let count = await library.added.count
        XCTAssertEqual(count, 0)

        await library.set(grantsAccess: true)
        let again = makeStore(access: access, library: library)
        await again.start()
        XCTAssertEqual(finished(again)?.imported, 1)
    }

    func testARememberedFolderThatListsNothingAsksForTheFolder() async throws {
        try FileManager.default.createDirectory(at: camera, withIntermediateDirectories: true)
        let access = FakeFolderAccess()
        let library = FakeLibrary()

        let store = makeStore(access: access, library: library)
        await store.start()
        XCTAssertTrue(store.isPickingFolder, "nothing remembered")
        XCTAssertEqual(store.phase, .idle)

        store.isPickingFolder = false
        access.remembered = camera
        await store.start()
        XCTAssertTrue(store.isPickingFolder, "a remembered folder that lists nothing")
        XCTAssertEqual(store.phase, .idle)
        let requests = await library.accessRequests
        XCTAssertEqual(requests, 0)

        // The same empty folder, picked: an empty card, said as such.
        store.isPickingFolder = false
        await store.importFrom(picked: camera)
        XCTAssertFalse(store.isPickingFolder)
        XCTAssertEqual(finished(store)?.imported, 0)
    }

    func testAnEmptyFirstListingIsLookedAtOnceMore() async throws {
        try put(["IMG_1.jpg"])
        let access = FakeFolderAccess()
        access.remembered = camera
        let library = FakeLibrary()
        let scanner = EmptyOnceScanner()

        let store = makeStore(access: access, library: library, scanner: scanner)
        await store.start()
        XCTAssertEqual(scanner.callCount, 2)
        XCTAssertFalse(store.isPickingFolder)
        XCTAssertEqual(finished(store)?.imported, 1)
    }

    func testStoppingEndsAfterTheFileInHandAndTheNextRunFinishes() async throws {
        try put(["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
        let access = FakeFolderAccess()
        let library = FakeLibrary()
        let store = makeStore(access: access, library: library)
        await library.set(onAdd: { await MainActor.run { store.stop() } })

        await store.importFrom(picked: camera)
        let result = try XCTUnwrap(finished(store))
        XCTAssertTrue(result.stopped)
        XCTAssertEqual(result.imported, 1)

        let again = makeStore(access: access, library: library)
        await again.start()
        XCTAssertEqual(finished(again)?.imported, 2)
        let names = await library.addedNames
        XCTAssertEqual(names, ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
    }
}
