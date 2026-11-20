import Foundation

/// What Photos is handed a camera file as.
public enum CameraImportKind: String, Sendable {
    case photo
    case video

    /// The kind a file name's extension stands for, nil for everything not imported: the
    /// low-resolution `.lrv` proxies and `.thm` thumbnails an action camera writes beside each
    /// video, and whatever else sits on the card.
    public init?(fileName: String) {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "jpg", "jpeg", "dng", "heic", "heif": self = .photo
        case "mp4", "mov": self = .video
        default: return nil
        }
    }
}

/// One file found in the camera's folder.
public struct CameraImportFile: Equatable, Sendable {
    public let url: URL
    public let size: Int64

    public init(url: URL, size: Int64) {
        self.url = url
        self.size = size
    }

    public var name: String { url.lastPathComponent }
    public var kind: CameraImportKind? { CameraImportKind(fileName: name) }

    /// What the ledger remembers a file by: its name and size, not its path, so the same file is
    /// recognised whether the volume root, `DCIM` or the camera's own subfolder was picked. The
    /// modification date stays out: a FAT volume stores local time without a zone, so the same
    /// file can read back with another date after the phone changed time zone.
    public var ledgerKey: String { "\(name)|\(size)" }
}

/// Which of a folder's files a run imports.
public struct CameraImportPlan: Equatable, Sendable {
    /// Photos and videos not imported before, in name order (an action camera's names carry the
    /// capture time).
    public let toImport: [CameraImportFile]
    public let alreadyImported: Int
    /// Files that are not a photo or video this imports: proxies, thumbnails, anything else.
    public let ignored: Int

    public init(files: [CameraImportFile], imported: Set<String>) {
        var seen = imported
        var toImport: [CameraImportFile] = []
        var alreadyImported = 0
        var ignored = 0
        let ordered = files.sorted { ($0.name, $0.url.path) < ($1.name, $1.url.path) }
        for file in ordered {
            guard file.kind != nil else {
                ignored += 1
                continue
            }
            if seen.insert(file.ledgerKey).inserted {
                toImport.append(file)
            } else {
                alreadyImported += 1
            }
        }
        self.toImport = toImport
        self.alreadyImported = alreadyImported
        self.ignored = ignored
    }
}
