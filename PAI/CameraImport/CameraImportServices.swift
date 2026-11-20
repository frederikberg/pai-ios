import Foundation
import PAIKit
import Photos

/// The camera folder through a bookmark kept in `UserDefaults`. A bookmark onto an external drive
/// may stop resolving once the drive is unplugged; `openRemembered` then answers nil and the
/// screen asks for the folder again.
struct CameraFolderBookmarks: CameraFolderAccess {
    private static let key = "cameraImport.folderBookmark"

    private var defaults: UserDefaults { .standard }

    func openRemembered() -> CameraFolderGrant? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale),
            url.startAccessingSecurityScopedResource()
        else { return nil }
        if isStale { remember(url) }
        return CameraFolderGrant(url: url) { url.stopAccessingSecurityScopedResource() }
    }

    func open(picked url: URL) -> CameraFolderGrant {
        // A picked URL normally needs this call; one that does not still opens, so a false here
        // is no reason to refuse it.
        let accessing = url.startAccessingSecurityScopedResource()
        remember(url)
        return CameraFolderGrant(url: url) {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .minimalBookmark) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The phone's photo library with add-only access, which is all an import needs and the one
/// permission that cannot read the library.
struct PhotoLibraryCameraWriter: CameraImportLibrary {
    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Handed over by file URL, so Photos copies the camera's bytes as they are (metadata
    /// included) and memory stays flat for a large video. The creation date is left to Photos,
    /// which reads it from the file.
    func add(_ file: URL, kind: CameraImportKind, originalFilename: String, movingFile: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = originalFilename
            options.shouldMoveFile = movingFile
            PHAssetCreationRequest.forAsset().addResource(
                with: kind == .video ? .video : .photo, fileURL: file, options: options)
        }
    }
}
