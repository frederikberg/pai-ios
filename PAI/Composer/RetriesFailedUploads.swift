import PAIKit
import SwiftUI

/// Tries a composer's failed uploads again by themselves: when the network comes back, when the
/// app returns to the front, and every ``interval`` while the composer is on screen. The chip's
/// retry button stays for anyone who will not wait.
struct RetriesFailedUploads: ViewModifier {
    static let interval: Duration = .seconds(30)

    let sessionID: String
    @Environment(StagedAttachmentStore.self) private var staging
    @Environment(DraftStore.self) private var drafts
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: sessionID) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.interval)
                    if Task.isCancelled { return }
                    staging.retryFailed(in: sessionID, via: drafts)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { staging.retryFailed(in: sessionID, via: drafts) }
            }
            .onChange(of: staging.networkRegained) { _, _ in
                staging.retryFailed(in: sessionID, via: drafts)
            }
    }
}

extension View {
    func retriesFailedUploads(in sessionID: String) -> some View {
        modifier(RetriesFailedUploads(sessionID: sessionID))
    }
}
