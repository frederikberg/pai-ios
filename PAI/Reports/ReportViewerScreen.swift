import PAIKit
import SwiftUI

/// One report: its page, the answers the page reports, and under it the message bar of the
/// session it came from, which sends the answers with what is typed there. Swift port of `ReportViewer.tsx`. Back is the navigation stack's own: a report opened
/// from a session's reply sits on top of that session.
struct ReportViewerScreen: View {
    let reportID: String
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: ReportViewerStore?
    @State private var pendingLink: URL?
    @State private var confirmingDelete = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            if let store {
                content(store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(store?.report?.title ?? "Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .accessibilityIdentifier("report-viewer-screen")
        .fixtureFact("reportBar", barFact)
        .task {
            guard store == nil, let connection = environment.connection else { return }
            let sessions = connection.sessions
            let current = ReportViewerStore(
                reportID: reportID, api: connection.apiClient, drafts: connection.drafts,
                sessionLoads: { id in
                    await sessions.ensureSessionLoaded(id: id)
                    return sessions.session(withId: id) != nil
                })
            store = current
            await current.load()
        }
        .onDisappear { Task { await store?.leave() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await store?.leave() } }
        }
        .confirmationDialog(
            "Open this link?", isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            titleVisibility: .visible
        ) {
            Button("Open") {
                if let url = pendingLink { UIApplication.shared.open(url) }
                pendingLink = nil
            }
            Button("Cancel", role: .cancel) { pendingLink = nil }
        }
        .confirmationDialog("Delete this report for good?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await store?.delete() == true { environment.router.pop() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Whether the message bar is shown, and whether it offers the answers.
    private var barFact: String {
        guard let store, store.hasComposer else { return "none" }
        return store.rider == nil ? "bar" : "answers"
    }

    @ViewBuilder
    private func content(_ store: ReportViewerStore) -> some View {
        if let error = failure ?? store.errorMessage {
            Text(error)
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        } else if let html = store.pageHTML {
            ReportWebView(
                html: html,
                onMessage: { store.receive(json: $0) },
                onConnect: { store.deliver = $0 },
                onOpenLink: { pendingLink = $0 },
                onFailure: { failure = $0 }
            )
            .accessibilityIdentifier("report-page")
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let notice = store.notice {
            NoticeBar(notice: notice, dismiss: { store.dismissNotice() }) { sessionID in
                environment.router.surface(.session(id: sessionID))
            }
        }
        if store.hasComposer, let sessionID = store.report?.sessionId, store.errorMessage == nil {
            Divider()
            ComposerBar(sessionID: sessionID, rider: rider(store)) {
                // The message and its reply are in the session.
                environment.router.surface(.session(id: sessionID))
            }
        }
    }

    /// The answers the next message carries, as the composer shows and sends them.
    private func rider(_ store: ReportViewerStore) -> ComposerRider? {
        guard let rider = store.rider else { return nil }
        return ComposerRider(
            label: ReportViewerStore.riderLabel(rider), text: rider.text,
            onLeaveOut: { store.leaveAnswersOut() }, onCarried: { store.answersWereSent(rider.text) })
    }

    /// The session this report came from, when the stack does not already hold it underneath
    /// (a report opened from a link outside the app, or from the list).
    private var sessionToOffer: String? {
        guard let id = store?.report?.sessionId else { return nil }
        return environment.router.path.contains(.session(id: id)) ? nil : id
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                if store?.isUnsaved == true {
                    Text("Not saved yet")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.amber500)
                }
                if let session = sessionToOffer {
                    Button {
                        environment.router.surface(.session(id: session))
                    } label: {
                        Image(systemName: "bubble.left")
                    }
                    .accessibilityLabel("Open the session")
                }
                if store?.report != nil {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete report")
                }
            }
        }
    }
}

/// The line at the foot after Add to message: where the answers went, and the way back.
private struct NoticeBar: View {
    let notice: ReportViewerStore.Notice
    let dismiss: () -> Void
    let openSession: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(notice.text)
                .font(PaiTypography.body.font)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let sessionID = notice.sessionId {
                Button("Back to the session") { openSession(sessionID) }
                    .buttonStyle(.borderedProminent)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.bar)
        .accessibilityIdentifier("report-notice")
    }
}
