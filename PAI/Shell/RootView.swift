import PAIKit
import SwiftUI
import UserNotifications

/// The app's outermost screen: the gate, and the navigation stack behind it.
struct RootView: View {
    @State private var environment = AppEnvironment.shared
    /// Whatever `CrashReporter` captured before this launch, if any — read once on appear rather
    /// than continuously, since nothing after launch can change what already happened before it.
    @State private var pendingCrash: CrashRecord?
    @Environment(\.scenePhase) private var scenePhase
    /// The account-wide notification stream — live only while the phone is actually
    /// in front of the reader. Rebuilt on every foreground rather than reused across a
    /// background/foreground cycle: `PaiNotificationStreamClient.disconnect()` is a one-shot stop
    /// for the whole instance, matching `PaiSseClient`'s own lifetime, so "resume" here means a
    /// fresh client the same way opening a session again builds a fresh `PaiSseClient` rather
    /// than un-stopping the old one.
    @State private var notificationStream: PaiNotificationStreamClient?
    /// When a notification for the open session counts as seen — see `SessionAttention`.
    @State private var attention = SessionAttention()
    /// A notification arriving while the app is open: nothing is pushed while it is in use, so this
    /// shows it instead.
    @State private var arrivals = ArrivalBannerStore()
    /// Tells the server while the app is in front, so no device of this person is pushed meanwhile.
    @State private var presence: PresenceReporter?
    /// The New todo sheet, opened by the control and the Home Screen quick actions, in the mode
    /// the way in asked for.
    @State private var addingTodo = false
    @State private var addingMode: TodoAddMode = .line
    /// A todo opened from outside: a nudge's push, a link to it, or the first of the todos plain
    /// words became in the sheet above.
    @State private var openedTodo: TodoSheetTarget?

    /// The parked deep link, if one is waiting. Read through the observable inbox rather than
    /// polled, so a notification tapped while the app is already open navigates immediately
    /// rather than on whatever the next redraw happens to be.
    private var deepLinks: DeepLinkInbox { DeepLinkInbox.shared }

    var body: some View {
        content
            .preferredColorScheme(colorScheme)
            .task(id: environment.connection == nil) {
                await environment.loadStartupState()
                // Set once, unconditionally, rather than left to the `.onChange` below — that
                // only fires on an actual change, so a badge APNs set while the app was
                // backgrounded and then cleared elsewhere (the web, another device) never gets a
                // change to react to here: the launch value and the freshly fetched true value
                // are both zero, and a badge stuck showing a stale count survives indefinitely.
                if let unread = environment.connection?.notifications.unread {
                    try? await UNUserNotificationCenter.current().setBadgeCount(badgeCount(unread: unread))
                }
                // The delivered-notification half of the same self-heal: a banner
                // read from elsewhere while this app was not running yet has no earlier moment
                // to have been cleared at.
                if let connection = environment.connection {
                    await PushRegistrar.reconcileDeliveredNotifications(against: connection.notifications)
                    connectNotificationStream(connection)
                }
                // Concurrent, not sequential: `pollMachines()` never returns on its own (it loops
                // until the task is cancelled), so chaining a second poll after it would simply
                // never run.
                async let machinePoll: Void = environment.pollMachines()
                async let notificationPoll: Void = environment.pollNotificationSummary()
                _ = await (machinePoll, notificationPoll)
            }
            .onAppear { pendingCrash = CrashReporter.readUnseen() }
            // Sleep time begins and ends on the clock, so something has to look at it: a timer to the
            // next boundary, every return to the front, and the clock or the time zone changing.
            .task(id: environment.sleepMode.nextBoundary) { await sleepUntilNextBoundary() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) {
                _ in
                environment.sleepMode.refresh()
                syncSleepToServer()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in
                environment.sleepMode.refresh()
                syncSleepToServer()
            }
            // The window this phone holds is what the server holds pushes back by: told again
            // whenever the window or the wake-early moment changes, and above whenever the clock or
            // the zone it is read in does.
            .onChange(of: environment.sleepMode.settings) { _, _ in syncSleepToServer() }
            // The springboard badge reads zero while the sessions are put away and the unread count
            // again once the window ends.
            .onChange(of: environment.router.isAsleep) { _, _ in
                guard let unread = environment.connection?.notifications.unread else { return }
                Task { try? await UNUserNotificationCenter.current().setBadgeCount(badgeCount(unread: unread)) }
            }
            // What a screenshot run checks first: behind the sign-in gate, every screen it asks for
            // is the sign-in screen.
            .fixtureFact("gate", String(describing: environment.router.gate))
            // Two triggers, because a link and a usable app arrive in either order: tapped while
            // the app is open, the link is last; tapped from cold, the gate opening is last.
            .onChange(of: deepLinks.pending) { _, _ in consumeDeepLink() }
            .onChange(of: environment.router.gate) { _, _ in consumeDeepLink() }
            // Reaching a session — by any route other than tapping the notification itself,
            // which already marks its own row read on the way in
            // (`resolveAndOpenNotification`) — clears whatever is still waiting for it, once the
            // reader is engaged (`SessionAttention`): the tap that opened it clears at once, a
            // session restored at launch waits for the first touch. Read from the router rather
            // than tracked separately, the same reason `openSessionID` itself is derived: the
            // session list, a deep link, and a freshly created session all funnel through this one
            // value changing. The live-arrival case (a notification for the session already on
            // screen) is handled where it arrives, in `connectNotificationStream`'s
            // `onNotification`, under the same rule.
            .onChange(of: environment.router.openSessionID) { _, sessionID in
                guard let sessionID, let store = environment.connection?.notifications else { return }
                if attention.shouldClearNow(sessionID) {
                    Task { await store.markSessionRead(sessionID) }
                }
            }
            // The held request is released by the next touch or key in any window.
            .onAppear {
                UserActivityRecognizer.onActivity = { [attention, environment] in
                    guard let held = attention.noteActivity(), held == environment.router.openSessionID,
                        let store = environment.connection?.notifications
                    else { return }
                    Task { await store.markSessionRead(held) }
                }
                UserActivityRecognizer.installOnAllWindows()
            }
            // The URL half — a shortcut or widget that opens the app by URL rather than through
            // an App Intent, and a universal link tapped in another app, which SwiftUI hands
            // here as its URL rather than as a browsing user activity. Parked through the same
            // inbox so there is one path to a screen from outside, not two that can disagree.
            .onOpenURL { url in
                guard let link = DeepLink.from(url: url) ?? DeepLink.from(webURL: url) else { return }
                deepLinks.receive(link)
            }
            // The network came back while the app is in front: replace a stream the path change
            // may have killed without a word.
            .onReceive(NotificationCenter.default.publisher(for: StreamWake.name)) { note in
                notificationStream?.reviveIfStale(force: StreamWake.isForced(note))
            }
            // Presented once per capture, then only marked seen — never deleted on dismiss: this is
            // the only capture of the reason string Apple's own crash report leaves out, so the
            // file stays reachable from Settings until deleted there or through the debug bridge's
            // `POST /crash/clear`.
            .sheet(item: $pendingCrash) { crash in
                CrashReportSheet(record: crash)
                    .onAppear { CrashReporter.markSeen(crash) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.router.gate {
        case .needsConfiguration:
            SignInView(environment: environment, reason: .firstLaunch)
        case .tokenRejected:
            SignInView(environment: environment, reason: .rejected(environment.lastAuthFailure))
        case .ready:
            if let connection = environment.connection {
                ZStack(alignment: .bottom) {
                    // A plain `VStack`, not `.safeAreaInset(edge: .top)` on the `NavigationStack`.
                    // The inset approach let the banner draw see-through over a pushed screen's
                    // own content instead of pushing it down — a pushed `List` that paints its own
                    // edge-to-edge background (`paiScreenBackground()`'s `ignoresSafeAreaEdges:
                    // .all`) does not reliably inherit an inset reserved by an ancestor outside the
                    // `NavigationStack`, across a UIKit-bridged push. A `VStack` sidesteps that
                    // whole class of interaction: the banner's natural height is ordinary layout,
                    // not a safe-area negotiation, so the `NavigationStack` genuinely gets a
                    // smaller frame rather than a promise of one. It still sits below the status
                    // bar the same way, since a `VStack` respects the top safe area by default.
                    VStack(spacing: 0) {
                        // About the agents' sign-in, so it waits with them.
                        if !environment.router.isAsleep { ClaudeAuthBanner() }
                        // Sits with the auth banner rather than inside the stack, and for the
                        // same reason its own comment gives: this has to push the screen down,
                        // not draw over it, and a pushed screen that paints its own background
                        // does not reliably honour a safe-area inset reserved outside the stack.
                        ComputerCallBar(
                            controller: connection.computerCall,
                            sessions: connection.sessions,
                            isShowingCall: environment.router.path.last == .computerCall
                        ) {
                            environment.router.surface(.computerCall)
                        }
                        NavigationStack(path: navigationPath) {
                            rootScreen
                                .navigationDestination(for: Route.self) { route in
                                    destination(for: route)
                                }
                        }
                    }
                    ToastOverlay(toasts: connection.toasts)
                }
                .overlay(alignment: .top) {
                    ArrivalBannerView(store: arrivals) { environment.router.surface(.notifications) }
                }
                // The one page ground for every screen the stack pushes — none of them paint
                // their own, so this is what stops each one falling through to pure black. See
                // `paiScreenBackground()`'s own doc comment for why that step matters.
                .paiScreenBackground()
                .sheet(isPresented: $addingTodo) {
                    TodoAddSheet(
                        todos: environment.todos,
                        draft: TodoCaptureDraft { [client = connection.apiClient] text in
                            try await client.todosParse(text: text, list: nil, source: .ios)
                        },
                        initialMode: addingMode,
                        onAdded: { changeId in reportAddedTodo(changeId, toasts: connection.toasts) },
                        onComposed: { composed in openComposedTodo(composed, toasts: connection.toasts) },
                        onAddedToOpen: { changeId, todoId in
                            openAddedTodo(changeId, todoId: todoId, toasts: connection.toasts)
                        })
                }
                .sheet(item: $openedTodo) { target in TodoSheetView(todoId: target.id) }
                .environment(environment)
                .environment(connection.sessions)
                .environment(connection.machines)
                .environment(connection.usage)
                .environment(connection.claudeAuth)
                .environment(connection.transcript)
                .environment(connection.settings)
                .environment(connection.drafts)
                .environment(connection.me)
                .environment(connection.selfReports)
                .environment(connection.toasts)
                .environment(connection.secretGrants)
                .environment(connection.notes)
                .environment(connection.notesBrowse)
                .environment(connection.noteMeaning)
                .environment(connection.staging)
                .environment(connection.outbox)
                .environment(connection.notifications)
                // Only settles a token the backend has not seen yet — silent, and a no-op in the
                // common case. Asking for permission is deliberately NOT here: the system prompt
                // appears at most once per install and never again, so spending it the instant
                // the app opens, over whatever screen happens to be in front of the person, is
                // the worst possible moment. It lives behind an explicit control in Settings.
                .task {
                    // 🚨 Both halves, every launch, and the order matters less than the fact that
                    // the first one happens at all. Apple's contract is that an app asks for a
                    // token on every launch, because a token is not permanent — a restore from
                    // backup or an OS-level rotation issues a new one and silently invalidates
                    // the old. Asking only from the Settings button would mean never asking
                    // again after the first grant, since that button is shown only while the
                    // permission is still unanswered. Push would then go quiet with the app
                    // still reporting notifications as on, which is the worst way to fail.
                    await PushRegistrar.registerForRemoteNotificationsIfAuthorized(store: connection.push)
                    // Whether this person's device may be registered depends on who they are.
                    await connection.me.ensureKnown()
                    await connection.push.setSleep(environment.sleepMode.deviceChoice())
                    await connection.push.registerWithBackendIfNeeded()
                    // Where a silent read-sync push actually reaches app code —
                    // `PushRegistrar.application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
                    // has no environment of its own to read `connection.notifications` from, since
                    // it can fire before this screen — or any screen — is on top. Set once here,
                    // the same way `PushRegistrar.store` is, and for the same reason.
                    PushRegistrar.notificationsStore = connection.notifications
                    // The scene was already active before the connection existed, so no phase
                    // change will report it.
                    if scenePhase == .active { presenceReporter(connection).setActive(true) }
                }
                .environment(\.terminalStreamClientFactory) { sessionID, callbacks in
                    PaiTerminalStreamClient(
                        sessionId: sessionID,
                        requestFactory: connection.requestFactory,
                        callbacks: callbacks
                    )
                }
                // Mirrors the unread count into the springboard badge — the
                // half `aps.badge` cannot cover, since that only ever updates the badge when a
                // push actually arrives, not when a swipe or a mark-all-read changes the count
                // from inside the running app.
                .onChange(of: connection.notifications.unread) { _, unread in
                    Task { try? await UNUserNotificationCenter.current().setBadgeCount(badgeCount(unread: unread)) }
                }
                // The stream is only ever worth holding open while this screen is actually in
                // front of the reader — see `notificationStream`'s own doc comment for why
                // backgrounding tears it down rather than merely pausing it, and why the
                // foreground side rebuilds rather than resumes. `.inactive` (a brief transitional
                // state — the app switcher, an interruption) is deliberately not a disconnect
                // trigger: treating it as one would thrash the connection on every such transition
                // with no benefit, since the process keeps running throughout.
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        environment.sleepMode.refresh()
                        syncSleepToServer()
                        attention.setAppActive(true)
                        presenceReporter(connection).setActive(true)
                        UserActivityRecognizer.installOnAllWindows()
                        AppVoiceDiagnosticsLog.shared.log(.info, .lifecycle, "app active")
                        connectNotificationStream(connection)
                        connection.wakeWordSamples.drain()
                        // A send or a dictation still owed to the server picks up at once rather
                        // than after whatever backoff it was waiting out while suspended.
                        connection.outbox.retryNow()
                        connection.voice.resumeOwedTakes()
                        Task { await connection.notes.resumeSync() }
                        // Todos waiting to go out leave now; what changed elsewhere is read.
                        environment.todos.retryNow()
                        Task { await environment.todos.catchUp() }
                        // Sync at once instead of up to a poll interval from now, and let the
                        // open transcript replace a connection the OS suspended while away.
                        connection.sessions.requestSync()
                        LocationReporter.shared.foregroundFix()
                        // A file shared into a session from another app is on its draft by now.
                        Task { await connection.drafts.syncFromServer() }
                        StreamWake.post(force: false)
                        Task {
                            await connection.notifications.refreshSummary()
                            await PushRegistrar.reconcileDeliveredNotifications(against: connection.notifications)
                        }
                        // Banners of alarms that stopped while the phone was away. Only a read
                        // that succeeded counts: no answer must not clear a ringing alarm's banners.
                        Task {
                            guard let list = try? await connection.apiClient.listAlarms() else { return }
                            await PushRegistrar.clearStoppedAlarmNotifications(ringing: Set(list.ringing.map(\.id)))
                        }
                    case .background:
                        environment.todos.flushCache()
                        attention.setAppActive(false)
                        presence?.setActive(false)
                        // The one place a backgrounding is guaranteed to be observed — flushed here
                        // rather than trusting the periodic loop alone, since a device suspended
                        // for hours right after this could otherwise lose everything since its
                        // last tick.
                        AppVoiceDiagnosticsLog.shared.log(.info, .lifecycle, "app backgrounded")
                        AppVoiceDiagnosticsLog.shared.flush()
                        notificationStream?.disconnect()
                        notificationStream = nil
                    case .inactive:
                        attention.setAppActive(false)
                        presence?.setActive(false)
                    @unknown default:
                        break
                    }
                }
            } else {
                // `ready` without a connection should be unreachable; showing sign-in is the only
                // state a user can act on, and a blank screen is the alternative.
                SignInView(environment: environment, reason: .firstLaunch)
            }
        }
    }

    /// The sleep screen while the sessions are put away, the session list otherwise.
    @ViewBuilder
    private var rootScreen: some View {
        if environment.router.isAsleep {
            SleepScreen()
        } else {
            SessionListView()
        }
    }

    /// Tells the backend this phone's sleep window if it differs from what it was last told.
    /// Nothing happens without a connection or a push token.
    private func syncSleepToServer() {
        guard let push = environment.connection?.push else { return }
        let choice = environment.sleepMode.deviceChoice()
        Task { await push.setSleep(choice) }
    }

    /// What the springboard badge shows: nothing while asleep.
    private func badgeCount(unread: Int) -> Int {
        environment.router.isAsleep ? 0 : unread
    }

    /// Waits for the moment `isAsleep` can next change, then recomputes it. Re-run whenever that
    /// moment changes, so a changed window or a woken-early night restarts the wait. A wait that
    /// ends a hair before the boundary on the wall clock looks again rather than giving up.
    private func sleepUntilNextBoundary() async {
        let sleep = environment.sleepMode
        while !Task.isCancelled, let boundary = sleep.nextBoundary {
            let wait = boundary.timeIntervalSinceNow
            do { try await Task.sleep(for: .seconds(max(wait, 0) + 0.05)) } catch { return }
            sleep.refresh()
            if sleep.nextBoundary != boundary { return }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .session(let id, let messageID):
            // Explicit identity, keyed on the session id alone (never `messageID` — see
            // `Route.session`'s own doc comment on why that stays out of equality). Without this,
            // `Router.replace(with:)` swapping a `.session(id: "A")` destination for a
            // `.session(id: "B")` one at the same stack depth can leave `NavigationStack` treating
            // it as the same destination updated in place rather than a new one pushed — a
            // documented `NavigationStack` bug when a path is replaced wholesale with a
            // same-length array whose values differ (Apple Feedback FB18336684). `SessionDetailView`
            // itself would still pick up the new title from its `sessionID` property either way,
            // since that part is plain SwiftUI state; what does not recover on its own is
            // `TranscriptCollectionView`'s `UIViewControllerRepresentable`, whose
            // `updateUIViewController` is deliberately a no-op (the controller is meant to be torn
            // down and rebuilt on every navigation into a session, never reconfigured for a new
            // one) — so a reused destination left session A's transcript view controller mounted
            // under session B's title. Forcing the identity here makes SwiftUI discard the whole
            // subtree and rebuild it, restoring "recreated on every navigation into a session" for
            // this path the same as an ordinary push already gets it for free.
            SessionDetailView(sessionID: id, initialJumpMessageID: messageID)
                .id(id)
        case .terminal(let sessionID):
            TerminalScreen(sessionID: sessionID)
        case .settings:
            SettingsScreen()
        case .createSession:
            CreateSessionRouteScreen()
        case .subagents(let parentID):
            SubagentListScreen(parentSessionId: parentID)
        case .notes:
            NoteListScreen()
        case .note(let id):
            // Same reasoning and the same fix as `.session` above — `Router.openNote(id:)` is the
            // one path that replaces a `.note(id:)` destination for a *different* note at the same
            // stack depth (`replace(with: [.notes, .note(id: id)])`), reached from a deep link or a
            // home-screen shortcut. `MarkdownSourceTextView`'s own `updateUIView` is not a no-op —
            // unlike the transcript's, it genuinely detects and applies a changed `text` — so a
            // reused destination would still end up showing the right note body. What it would not
            // recover on its own is `NoteEditorScreen`'s own screen-level `@State`: `titleText` and
            // `isTitleFocused` in particular, which a reused identity carries over from the note
            // just left. The concrete failure that opens: mid-edit on note A's title when a
            // shortcut switches to note B, `.onChange(of: title)` skips updating `titleText` because
            // `isTitleFocused` is still (stalely) true, and the next commit renames note B using
            // note A's half-typed title. `.id(id)` removes the whole class rather than patching
            // that one field.
            //
            // `startsInPreview` reads the stored preference rather than defaulting to edit: this
            // route names no mode of its own, so the last mode the user actively chose (the
            // editor's own toggle — see `NotesBrowseStore.previewMode`) decides, the same way the
            // web falls back to its stored preference whenever the address says nothing.
            NoteEditorScreen(noteID: id, startsInPreview: environment.connection?.notesBrowse.previewMode ?? false)
                .id(id)
        case .noteContainers:
            NoteContainersScreen()
        case .notePreview(let id, let heading):
            // Reached by an ordinary `push`, from `NoteBodyView` and from the fixture screenshot
            // workflow — never through `replace(with:)`, so this never hits the *same-depth*
            // reuse the two cases above guard against. Identity forced anyway, for the same
            // reason `.note` is: free, and it keeps every note-scoped destination consistent
            // rather than leaving one exception someone has to remember.
            NoteEditorScreen(noteID: id, startsInPreview: true, startsAtHeading: heading)
                .id(id)
        case .notifications:
            NotificationCenterScreen()
        case .recordings:
            RecordingsRouteScreen()
        case .arcSpec(let specUuid):
            // The session this spec was opened from, if the currently open route names one —
            // read from the path rather than threaded through the route itself, since the route
            // carries no session identity of its own (see `Route.arcSpec`'s doc comment). This
            // is only ever an approximation of "which session pushed this screen": correct for
            // the ordinary case (push from the session currently on top, or from that session's
            // own in-session swipe), and simply `nil` — no live SSE signal, poll fallback only —
            // for anything less direct, which is the safe default already documented on
            // `ArcSpecView.sessionID`.
            ArcSpecView(specUuid: specUuid, sessionID: environment.router.openSessionID)
        case .apps:
            AppsRouteScreen()
        case .arcSpecList:
            ArcSpecListView()
        case .arcReport(let specUuid, let reportUuid):
            ArcReportScreen(specUuid: specUuid, reportUuid: reportUuid)
        case .arcOverview(let specUuid):
            ArcOverviewRouteScreen(specUuid: specUuid)
        case .schedulerList:
            SchedulerListView()
        case .schedulerTask(let id):
            TaskEditorView(taskId: id)
        case .reminder(let id):
            ReminderDetailView(reminderId: id)
        case .quickActions:
            QuickActionsScreen()
        case .computerCall:
            ComputerCallView()
        case .canteen:
            CanteenView()
        case .alarm:
            AlarmView()
        case .weather:
            WeatherView()
        case .me:
            MeView()
        case .todos:
            TodoPageScreen(page: nil)
        case .todosBrowse:
            TodoBrowseScreen()
        case .todosPage(let page):
            TodoPageScreen(page: page)
        case .todosSearch:
            TodoSearchScreen()
        case .cameraImport:
            CameraImportView()
        case .usage:
            UsageView()
        case .decisions:
            DecisionsView()
        case .reports:
            ReportListScreen()
        case .report(let id):
            // Keyed on the report, like `.browser`: a link to another report replaces this
            // destination in place, and the page and its answers belong to one report each.
            ReportViewerScreen(reportID: id)
                .id(id)
        case .browserList:
            BrowserListScreen()
        case .browser(let name):
            // Keyed on the session, like `.session`: a link to another session replaces this
            // destination in place, and the stream and zoom belong to one session each.
            BrowserLiveScreen(name: name)
                .id(name)
        }
    }

    /// Act on a parked deep link, but only once there is a signed-in app to act on it in.
    ///
    /// Left in the inbox otherwise rather than dropped: a notification tapped from cold arrives
    /// well before the token has been read and the connection built, and discarding it there is
    /// exactly the case this whole mechanism exists for.
    private func consumeDeepLink() {
        guard environment.router.gate == .ready, let connection = environment.connection else { return }
        guard let link = deepLinks.consume() else { return }
        // A link the reader followed from outside the app (a tapped banner, a widget, a shortcut)
        // is a deliberate open with no touch inside the app to show for it.
        attention.noteActivity()
        // The add sheet opens over whatever is on screen; the navigation stays where it was.
        if link == .newTodo || link == .describeTodo {
            addingMode = link == .describeTodo ? .describe : .line
            OverlayDismissal.dismissAll { addingTodo = true }
            return
        }
        // A todo by its number: the page the link names, then the todo's own sheet over it.
        if case .todos(_, let number?) = link {
            OverlayDismissal.dismissAll {
                environment.router.replace(with: link.routes)
                Task { await openTodo(number: number, toasts: connection.toasts) }
            }
            return
        }
        // `.notification` is the one case `DeepLink.routes` cannot answer on its own — see its
        // doc comment. Resolving it needs a network round trip, so it gets its own path instead
        // of the synchronous `replace(with: link.routes)` every other case uses.
        if case .notification(let id) = link {
            Task { await resolveAndOpenNotification(id: id, connection: connection) }
            return
        }
        // A tapped alarm push stops that alarm on the server, so every device stops ringing; the
        // Alarm screen it opens shows the result on its next read.
        if case .alarm(let id?) = link {
            Task {
                do {
                    try await connection.apiClient.dismissAlarm(id: id)
                } catch {
                    connection.toasts.show(
                        (error as? PaiError)?.userMessage ?? "Could not stop the alarm", kind: .error)
                }
            }
        }
        guard link.dismissesOverlays else {
            environment.router.replace(with: link.routes)
            return
        }
        // Routed only once the overlays are gone — see `OverlayDismissal`.
        OverlayDismissal.dismissAll { environment.router.replace(with: link.routes) }
    }

    /// Opens the todo numbered `number`, read from the server when the phone does not hold it.
    private func openTodo(number: Int, toasts: ToastCenter) async {
        guard let id = await environment.todos.todoId(number: number) else {
            toasts.show("T-\(number) could not be opened.", kind: .error)
            return
        }
        openedTodo = TodoSheetTarget(id: id)
    }

    /// A todo added to be opened: once the server has it, its sheet opens.
    private func openAddedTodo(_ changeId: String, todoId: String, toasts: ToastCenter) {
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            switch await environment.todos.settled(changeId, timeout: 15) {
            case .applied: openedTodo = TodoSheetTarget(id: todoId)
            case .refused(let refusal): toasts.show("Not added: \(refusal.message)", kind: .error)
            case .waiting:
                toasts.show("Saved on this iPhone. It is added once there is a connection.", kind: .info)
            }
        }
    }

    /// Plain words became todos: once the server has them the first one opens; several say how
    /// many came in.
    private func openComposedTodo(_ composed: TodosComposed, toasts: ToastCenter) {
        Task {
            // The add sheet is still leaving; a sheet asked for meanwhile is dropped.
            try? await Task.sleep(for: .milliseconds(700))
            switch await environment.todos.settled(composed.changeId, timeout: 15) {
            case .applied:
                if composed.count > 1 {
                    TodoUndoToast.show(
                        "Added \(composed.count) todos", changeId: composed.changeId, store: environment.todos,
                        toasts: toasts)
                }
                openedTodo = TodoSheetTarget(id: composed.firstTodoId)
            case .refused(let refusal):
                toasts.show("Not added: \(refusal.message)", kind: .error)
            case .waiting:
                toasts.show("Saved on this iPhone. It is added once there is a connection.", kind: .info)
            }
        }
    }

    /// Says how a todo from the add sheet went: added, refused, or kept on the phone until it can
    /// go out. The store tells no refusal of its own for a change someone waits on.
    private func reportAddedTodo(_ changeId: String, toasts: ToastCenter) {
        Task {
            let outcome = await environment.todos.outcome(of: changeId, timeout: 4)
            switch outcome.settlement {
            case .refused: toasts.show(outcome.message(keeper: .app), kind: .error)
            case .applied, .waiting:
                TodoUndoToast.show(
                    outcome.message(keeper: .app), changeId: changeId, store: environment.todos, toasts: toasts)
            }
        }
    }

    /// What a tapped push notification does once the app can act on it. The payload
    /// only ever carries the notification's own id — the anchor is not resolved at send time —
    /// so this fetches it fresh and routes on what comes back, rather than trusting anything
    /// stale the push itself might have carried.
    ///
    /// Always replaces the whole stack: a cold push arrives knowing nothing about what the app
    /// was showing (`Route.session`'s own doc comment), which is also right for a push tapped
    /// while the app happens to be open — that is a different action from an in-app tap on a row
    /// inside the centre, which `NotificationCenterScreen.open(_:)` handles by pushing instead,
    /// so Back there returns to the list rather than wherever the reader was before the push.
    private func resolveAndOpenNotification(id: String, connection: AppEnvironment.Connection) async {
        guard let notification = try? await connection.apiClient.getNotification(id: id) else {
            environment.router.replace(with: [.notifications])
            return
        }
        await connection.notifications.markRead(id)
        switch notification.kind {
        case .alert:
            environment.router.replace(with: [.notifications])
            connection.notifications.focus(id: notification.id)
        case .reminder:
            // The Scheduler underneath so Back has somewhere to go; a reminder deleted since leaves
            // the centre, where the row is the record.
            guard let reminderId = notification.reminderId else {
                environment.router.replace(with: [.notifications])
                return
            }
            environment.router.replace(with: [.schedulerList, .reminder(id: reminderId)])
        case .agent:
            guard let sessionId = notification.sessionId else {
                // The session is gone — nowhere to land. The centre is the honest fallback: the
                // notification is real and now marked read, there is simply no transcript left
                // to show for it.
                environment.router.replace(with: [.notifications])
                return
            }
            // A transcript that stays mounted read its jump target once, at construction, so it
            // is sent this one through `TranscriptJumpRequests` — see `Router.openSession`.
            let messageID = notification.anchor?.messageId
            if environment.router.openSession(id: sessionId, messageID: messageID), let messageID {
                connection.transcriptJumps.request(sessionID: sessionId, messageID: messageID)
            }
        }
    }

    /// Builds and connects a fresh notification stream client, replacing whatever was there —
    /// safe to call more than once for the same reason `PushRegistrar.registerForRemoteNotificationsIfAuthorized`
    /// is: idempotent bookkeeping rather than a user-facing action. `onRead` is where the live stream
    /// and the silent push actually meet — a read event both corrects the badge count immediately (through
    /// `applyLiveUnread`, which `.onChange(of: connection.notifications.unread)` above already
    /// mirrors into the springboard) and sweeps whatever delivered banners that same change just
    /// caught up with. `onNotification` only ever updates the count: the row itself is not
    /// injected into `NotificationCenterStore.rows`, since nothing reads that list outside the
    /// centre screen, which reloads its own page on entry regardless.
    private func connectNotificationStream(_ connection: AppEnvironment.Connection) {
        let store = connection.notifications
        let client = PaiNotificationStreamClient(
            requestFactory: connection.requestFactory,
            callbacks: PaiNotificationStreamClient.Callbacks(
                onNotification: { [weak store, arrivals] event in
                    store?.applyLiveUnread(event.unread)
                    // No banner while the sessions are put away: it would be about them.
                    if !environment.router.isAsleep { arrivals.show(event.notification) }
                    // Arriving for the session already on screen clears it under the same rule as
                    // reaching the session above: at once while the reader is engaged, otherwise
                    // at the next touch.
                    if let sessionId = event.notification.sessionId, sessionId == environment.router.openSessionID,
                        attention.shouldClearNow(sessionId)
                    {
                        Task { [weak store] in await store?.markSessionRead(sessionId) }
                    }
                },
                onRead: { [weak store] event in
                    store?.applyLiveUnread(event.unread)
                    guard let store else { return }
                    Task { await PushRegistrar.reconcileDeliveredNotifications(against: store) }
                },
                // The list is an incremental sync; the stream only says when to run it. Connecting
                // runs one too, since the stream replays nothing from while it was down.
                onSessionsChanged: { [weak sessions = connection.sessions] in sessions?.requestSync() },
                // Read again on connect too: an event sent while the stream was down is not replayed.
                onDecisionsChanged: { [weak decisions = connection.decisions] in
                    Task { await decisions?.refresh() }
                },
                onActivity: {},
                onConnected: { [weak sessions = connection.sessions, weak decisions = connection.decisions] in
                    sessions?.requestSync()
                    Task { await decisions?.refresh() }
                },
                onDisconnected: {}
            )
        )
        notificationStream = client
        client.connect()
    }

    /// Built on first use from the connection's client, then kept for the app's life.
    private func presenceReporter(_ connection: AppEnvironment.Connection) -> PresenceReporter {
        if let presence { return presence }
        let client = connection.apiClient
        let clientId = PresenceReporter.clientId()
        let reporter = PresenceReporter(report: { active in
            try? await client.reportPresence(clientId: clientId, active: active)
        })
        presence = reporter
        return reporter
    }

    /// `nil` is "follow the system", which is what an absent override means to SwiftUI too.
    private var colorScheme: ColorScheme? {
        switch environment.connection?.settings.theme ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// `set` only ever runs for a change `NavigationStack` itself drove — a swipe back, the back
    /// button, or a long-press jump to an ancestor — never for a programmatic push or replace,
    /// which mutate `Router.path` directly and reach this view through `get` on the next render.
    /// That is what makes `pathAfterLeavingSubagents` safe to apply unconditionally here: it must
    /// correct exactly the interactive case and never a deliberate `Router.replace(with:)` such
    /// as a notification's cold open, which intentionally lands somewhere `Route.subagents` knows
    /// nothing about.
    ///
    /// Back out of a session the new-session screen just opened is left entirely alone here —
    /// the push landed on an empty path (the create screen is a sheet with nothing on it), so an
    /// interactive pop simply empties the path back out, which is what reveals the plain session
    /// list underneath. There is nothing to correct.
    private var navigationPath: Binding<[Route]> {
        Binding(
            get: { environment.router.path },
            set: { newValue in
                let corrected = Route.pathAfterLeavingSubagents(from: environment.router.path, to: newValue)
                environment.router.replace(with: corrected)
            }
        )
    }
}

/// What `.createSession` pushes to — reproduces the real presentation (a sheet from the session
/// list) rather than pushing `CreateSessionView` directly, so the fixture screenshot workflow
/// photographs the exact thing the user sees rather than that view's own `NavigationStack` nested
/// inside this one with different, misleading chrome. See `Route.createSession`'s doc comment.
///
/// A home-screen shortcut reaches this same route (`DeepLink.createSession`), where — unlike the
/// fixture workflow — nothing else removes it: `CreateSessionView.send()` pushes `.session(id:)`
/// before dismissing (that function's own comment says why), so by the time this fires
/// `.createSession` may no longer be the top of the path — `Router.removeRoute` takes it out
/// wherever it sits rather than assuming it is still on top, so both Back (still on top) and a
/// successful send (now buried under the session just pushed) leave the reader on that session
/// rather than on a blank, transparent screen with a stray system Back button.
private struct CreateSessionRouteScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                CreateSessionView()
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else { return }
                environment.router.removeRoute(.createSession)
            }
    }
}

/// What `.apps` pushes to — reproduces the sheet the session list's "Apps" toolbar button
/// actually presents, since `AppsHomeSheet` has no screen of its own to navigate to. Real usage
/// never pushes this route, only the fixture screenshot workflow does — but `AppsHomeSheet.openArc()`/
/// `openNotes()`/`openScheduler()` push their own destination before dismissing, the same order
/// `CreateSessionRouteScreen` above has to account for, so this uses the same `removeRoute` fix
/// rather than the unconditional `pop()` that would otherwise remove whatever was just pushed.
private struct AppsRouteScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                AppsHomeSheet()
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else { return }
                environment.router.removeRoute(.apps)
            }
    }
}

/// What `.recordings` pushes to — reproduces the sheet the composer's plus-icon actually
/// presents, since `RecordingsSheet` has no screen of its own to navigate to. See
/// `Route.recordings`'s doc comment for why this route exists at all; shaped exactly like
/// `CreateSessionRouteScreen` above, for the same reason.
private struct RecordingsRouteScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                if let voice = environment.connection?.voice {
                    RecordingsSheet(
                        controller: voice,
                        onInsertTranscript: { _ in },
                        onAttachVoiceLog: { _ in }
                    )
                }
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else { return }
                environment.router.pop()
            }
    }
}

/// What `.arcOverview` pushes to — reproduces the sheet `ArcSpecView`'s own header button
/// presents, since the overview has no screen of its own to navigate to; real usage never
/// pushes this route, only the fixture screenshot workflow does. Fetches the overview text
/// directly rather than depending on `ArcSpecStore` having loaded, since the whole point is a
/// screenshot the app can reach with nothing else on screen underneath. Shaped exactly like
/// `CreateSessionRouteScreen` above, for the same reason.
private struct ArcOverviewRouteScreen: View {
    let specUuid: String
    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = true
    @State private var overview: String?

    var body: some View {
        Color.clear
            .task {
                guard let client = environment.connection?.apiClient else { return }
                overview = try? await client.getArcRecover(specUuid: specUuid).overview
            }
            .sheet(isPresented: $isPresented) {
                if let overview {
                    ArcMarkdownFullScreenView(markdown: overview, title: "Overview")
                }
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else { return }
                environment.router.pop()
            }
    }
}
