import PAIKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Camera Import: adds the photos and videos of a camera plugged in by USB-C to the photo library,
/// each file once. `CameraImportStore` decides what is imported; this holds the folder picker and
/// keeps the screen awake while a run is going.
struct CameraImportView: View {
    @State private var store: CameraImportStore?

    var body: some View {
        Group {
            if let store {
                CameraImportContent(store: store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Camera Import")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard store == nil else { return }
            let made = Self.makeStore()
            store = made
            #if DEBUG
                if PaiFixtureLaunch.isEnabled() && PaiFixtureLaunch.runsCameraImport() { await made.start() }
            #endif
        }
        // A run left going behind a popped screen could overlap the next screen's run and add the
        // same files twice; it ends after the file in hand instead.
        .onDisappear {
            store?.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .fixtureFact("cameraImport", factName)
    }

    private var factName: String { store?.phase.factName ?? "none" }

    private static func makeStore() -> CameraImportStore {
        #if DEBUG
            if PaiFixtureLaunch.isEnabled() && PaiFixtureLaunch.runsCameraImport() {
                return CameraImportFixture.makeStore()
            }
        #endif
        return CameraImportStore(
            access: CameraFolderBookmarks(), library: PhotoLibraryCameraWriter(),
            ledger: CameraImportLedger(
                fileURL: URL.applicationSupportDirectory.appending(path: "CameraImport/imported.json")),
            stagingDirectory: URL.temporaryDirectory.appending(path: "CameraImport", directoryHint: .isDirectory))
    }
}

private struct CameraImportContent: View {
    @Bindable var store: CameraImportStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                state
                actions
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(isPresented: $store.isPickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await store.importFrom(picked: url) }
            case .failure(let error): store.pickerFailed(error)
            }
        }
        .onChange(of: store.isBusy, initial: true) { _, busy in
            UIApplication.shared.isIdleTimerDisabled = busy
        }
    }

    @ViewBuilder
    private var state: some View {
        switch store.phase {
        case .idle:
            Text(
                "Plug the camera in by USB-C, then import. Every photo and video not imported before is added to Photos, where Immich picks it up."
            )
            .font(PaiTypography.body.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
        case .scanning:
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading the camera…")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        case .importing(let progress):
            CameraImportProgressView(progress: progress)
        case .finished(let result):
            CameraImportResultView(result: result)
        case .failed(let message):
            Text(message)
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
                .accessibilityIdentifier("camera-import-error")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if case .importing = store.phase {
            Button("Stop", role: .destructive) { store.stop() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("camera-import-stop")
        } else if !store.isBusy {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    Task { await store.start() }
                } label: {
                    Label("Import from Camera", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("camera-import-start")
                Button("Choose Folder") { store.isPickingFolder = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("camera-import-choose-folder")
            }
        }
    }
}

private struct CameraImportProgressView: View {
    let progress: CameraImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress.fraction)
            Text(count)
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            Text(progress.current)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityIdentifier("camera-import-progress")
    }

    private var count: String { "\(progress.done) of \(progress.total)" }
}

private struct CameraImportResultView: View {
    let result: CameraImportResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(PaiTypography.panelTitle.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if !result.failures.isEmpty {
                Text(failedHeading)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .padding(.top, 8)
                ForEach(result.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.name)
                            .font(PaiTypography.body.font)
                            .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        Text(failure.reason)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
            }
        }
        .accessibilityIdentifier("camera-import-result")
    }

    private var headline: String {
        if result.imported == 0 && result.failures.isEmpty { return "Nothing new" }
        return result.imported == 1 ? "1 file added to Photos" : "\(result.imported) files added to Photos"
    }

    private var lines: [String] {
        var lines: [String] = []
        if result.imported == 0 && result.alreadyImported == 0 && result.failures.isEmpty {
            lines.append("No photos or videos in “\(result.folderName)”.")
        } else {
            lines.append("From “\(result.folderName)”.")
        }
        if result.alreadyImported > 0 { lines.append("\(result.alreadyImported) imported before, skipped.") }
        if result.ignored > 0 { lines.append("\(result.ignored) other files skipped (video proxies, thumbnails).") }
        if result.stopped { lines.append("Stopped; the rest is imported next time.") }
        return lines
    }

    private var failedHeading: String {
        "\(result.failures.count) not imported, tried again next time"
    }
}
