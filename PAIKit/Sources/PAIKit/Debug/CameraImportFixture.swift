#if DEBUG

    import Foundation

    /// A camera folder and a photo library for the screenshot workflow, which has neither a
    /// camera nor a reason to fill the simulator's Photos.
    ///
    /// The folder is laid out like an action camera's volume (`DCIM/Camera01`) and remembered as
    /// its root, so the run walks into subfolders. One photo is already in the ledger, a proxy sits
    /// beside its video, and the library refuses one video both where it lies and as a copy: the
    /// finished screen then shows every line it has.
    public enum CameraImportFixture {
        public static let refusedName = "VID_20261120_103000_00_003.mp4"

        @MainActor
        public static func makeStore() -> CameraImportStore {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "camera-import-fixture", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            let camera = root.appendingPathComponent("volume/DCIM/Camera01", isDirectory: true)
            try? FileManager.default.createDirectory(at: camera, withIntermediateDirectories: true)
            let files = [
                "IMG_20261119_170000_00_000.jpg", "IMG_20261120_101500_00_001.jpg",
                "IMG_20261120_101500_00_001.dng", "VID_20261120_102000_00_002.mp4",
                "LRV_20261120_102000_01_002.lrv", refusedName,
            ]
            for name in files {
                _ = FileManager.default.createFile(
                    atPath: camera.appendingPathComponent(name).path, contents: Data(name.utf8))
            }
            var ledger = CameraImportLedger(fileURL: root.appendingPathComponent("imported.json"))
            try? ledger.record(
                CameraImportFile(
                    url: camera.appendingPathComponent(files[0]), size: Int64(Data(files[0].utf8).count)))
            return CameraImportStore(
                access: Access(folder: root.appendingPathComponent("volume", isDirectory: true)), library: Library(),
                ledger: ledger, stagingDirectory: root.appendingPathComponent("staging", isDirectory: true))
        }

        @MainActor
        private struct Access: CameraFolderAccess {
            let folder: URL
            func openRemembered() -> CameraFolderGrant? { CameraFolderGrant(url: folder) {} }
            func open(picked url: URL) -> CameraFolderGrant { CameraFolderGrant(url: url) {} }
        }

        private struct Library: CameraImportLibrary {
            func requestAccess() async -> Bool { true }

            func add(_ file: URL, kind: CameraImportKind, originalFilename: String, movingFile: Bool) async throws {
                try await Task.sleep(for: .milliseconds(300))
                if originalFilename == CameraImportFixture.refusedName { throw Refused() }
            }
        }

        private struct Refused: LocalizedError {
            var errorDescription: String? { "The file is damaged and could not be read." }
        }
    }

#endif
