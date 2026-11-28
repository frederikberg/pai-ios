import PAIKit
import SwiftUI

/// One screen for everything shared into the app: it becomes a todo, a note, or files waiting on
/// a session's draft.
struct ShareScreen: View {
    let providers: [NSItemProvider]
    let credentials: SharedCredentials?
    let close: () -> Void

    @State private var loaded: SharedItemLoader.Loaded?

    var body: some View {
        NavigationStack {
            Group {
                if let client {
                    if let loaded {
                        ShareFlowView(
                            store: ShareStore(
                                items: loaded.items, refusal: loaded.refusal, backend: client,
                                attemptMark: .extensionDefaults),
                            todo: ShareTodoStore(
                                sharedText: loaded.todoText, link: loaded.todoLink, files: loaded.files),
                            note: ShareNoteStore(
                                sharedText: loaded.todoText, link: loaded.todoLink, files: loaded.files),
                            client: client,
                            close: close)
                    } else {
                        ProgressView("Reading what you shared")
                    }
                } else {
                    ContentUnavailableView(
                        "Not signed in", systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Open PAI and sign in, then share again."))
                }
            }
            .navigationTitle("Share to PAI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                }
            }
        }
        .task {
            guard client != nil, loaded == nil else { return }
            loaded = await SharedItemLoader.load(providers)
        }
    }

    private var client: PaiApiClient? {
        guard let credentials else { return nil }
        let token = credentials.token
        guard
            let factory = try? PaiRequestFactory(
                baseURL: credentials.backendURL, deviceName: UIDevice.current.name, tokenProvider: { token })
        else { return nil }
        return PaiApiClient(requestFactory: factory)
    }
}

extension ShareAttemptMark {
    private static let key = "shareAttemptInProgress"

    static let extensionDefaults = ShareAttemptMark(
        isSet: { UserDefaults.standard.bool(forKey: key) },
        set: { UserDefaults.standard.set($0, forKey: key) })
}

private struct ShareFlowView: View {
    @State var store: ShareStore
    @State var todo: ShareTodoStore
    @State var note: ShareNoteStore
    let client: PaiApiClient
    let close: () -> Void

    /// The targets this person has; empty until the server has said who they are.
    @State private var offered: [ShareTarget] = []
    @State private var target = ShareTarget.session
    @State private var query = ""

    var body: some View {
        switch store.phase {
        case .choosing:
            if offered.isEmpty {
                ProgressView()
                    .task { await findTargets() }
            } else {
                chooser
            }
        case .sending(let done, let total):
            ProgressView("Attaching \(done + 1) of \(total)", value: Double(done), total: Double(total))
                .padding()
        case .sent(let destination):
            ContentUnavailableView(
                "Attached", systemImage: "checkmark.circle", description: Text(sentMessage(destination))
            )
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                close()
            }
        case .failed(let destination, let message):
            ContentUnavailableView {
                Label("Not everything arrived", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await store.send(to: destination) } }
            }
        }
    }

    /// Who the person is decides what is offered. Without an answer only the session is, the one
    /// target every signed-in person has.
    private func findTargets() async {
        let me = try? await client.getMe()
        let targets = ShareTarget.offered(to: Capabilities(me: me))
        todo.start(client)
        note.start(client)
        target = targets.first ?? .session
        offered = targets
    }

    private var chooser: some View {
        List {
            Section {
                ForEach(store.items) { item in
                    Label(item.name, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                }
                if let refusal = store.refusal {
                    Text(refusal).font(.footnote).foregroundStyle(.secondary)
                }
                if offered.count > 1 {
                    Picker("Share as", selection: $target) {
                        ForEach(offered) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("share-target")
                }
            }
            switch target {
            case .todo: ShareTodoSection(todo: todo, close: close)
            case .note: ShareNoteSection(note: note, close: close)
            case .session: sessionSections
            }
        }
        // On the list, not on the sessions' section: a section hands a task to each of its rows.
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await store.loadSessions(query: query)
        }
    }

    @ViewBuilder
    private var sessionSections: some View {
        if store.previousAttemptDied {
            Section {
                Label(
                    "The last share stopped before it finished, so its files may be missing.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
            }
        }
        if store.items.isEmpty {
            Section {
                Text("Nothing of what was shared can go to a session.").font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Section {
                Button {
                    Task { await store.send(to: .newSession) }
                } label: {
                    Label("New session", systemImage: "plus.bubble")
                }
            }
            Section("Sessions") {
                TextField("Search sessions", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let error = store.sessionsError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.sessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        let title = SessionListFormat.displayTitle(for: session)
        return Button(title) {
            Task { await store.send(to: .session(id: session.id, title: title)) }
        }
        .lineLimit(2)
    }

    private func sentMessage(_ destination: ShareDestination) -> String {
        switch destination {
        case .newSession: return "Waiting in New Session. Open PAI to start it."
        case .session(_, let title): return "Waiting in the composer of \(title)."
        }
    }
}
