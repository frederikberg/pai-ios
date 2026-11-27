#if DEBUG

    import Foundation

    /// Reads the launch arguments that drive the fixture screenshot workflow.
    ///
    /// `xcrun simctl launch <bundle> <args...>` appends its trailing arguments to the process's
    /// own `argv`, so they show up in `ProcessInfo.arguments` exactly as passed — no Xcode
    /// scheme, no `UserDefaults` argument-domain magic, just the array every launch already has.
    /// Parsing that array directly (rather than the `-Key value` → `UserDefaults` convention)
    /// keeps this testable with a plain `[String]` and keeps it working identically on Linux,
    /// where `UserDefaults` does not exist.
    public enum PaiFixtureLaunch {

        static let modeFlag = "-PaiFixtureMode"
        static let routeFlag = "-PaiFixtureRoute"
        static let authStateFlag = "-PaiFixtureAuthState"
        static let searchKindFlag = "-PaiFixtureSearchKind"
        static let openImageFlag = "-PaiFixtureOpenImage"
        static let openPdfFlag = "-PaiFixtureOpenPdf"
        static let jumpMessageFlag = "-PaiFixtureJumpMessage"
        static let autoCreateSessionFlag = "-PaiFixtureAutoCreateSession"
        static let secretPromptFlag = "-PaiFixtureSecretPrompt"
        static let draftTextFlag = "-PaiFixtureDraftText"
        static let newSessionTypeFlag = "-PaiFixtureNewSessionType"
        static let playbackFlag = "-PaiFixturePlayback"
        static let notesFilterFocusFlag = "-PaiFixtureNotesFilterFocused"
        static let offlineFlag = "-PaiFixtureOffline"
        static let notesCacheSeededFlag = "-PaiFixtureNotesCacheSeeded"
        static let notePendingEditFlag = "-PaiFixtureNotePendingEdit"
        static let noteConflictFlag = "-PaiFixtureNoteConflict"
        static let noteRefusedEditFlag = "-PaiFixtureNoteRefusedEdit"
        static let scrollAnchorFlag = "-PaiFixtureScrollTo"
        static let notificationSourceFlag = "-PaiFixtureNotificationSource"
        static let weatherFlag = "-PaiFixtureWeather"
        static let watchKeysFlag = "-PaiFixtureWatchKeys"
        static let cameraImportFlag = "-PaiFixtureCameraImport"
        static let meFlag = "-PaiFixtureMe"
        static let meTabFlag = "-PaiFixtureMeTab"
        static let schedulerSectionFlag = "-PaiFixtureSchedulerSection"
        static let meComposerFlag = "-PaiFixtureMeComposer"
        static let meDayFlag = "-PaiFixtureMeDay"
        static let alarmSheetFlag = "-PaiFixtureAlarmSheet"
        static let sessionFiltersFlag = "-PaiFixtureSessionFilters"
        static let quickMoreFlag = "-PaiFixtureQuickMore"
        static let quickEditFlag = "-PaiFixtureQuickEdit"
        static let quickShortcutsFlag = "-PaiFixtureQuickShortcuts"
        static let roleFlag = "-PaiFixtureRole"
        static let sleepFlag = "-PaiFixtureSleep"
        static let settingsCategoryFlag = "-PaiFixtureSettingsCategory"
        static let sleepSettingsFlag = "-PaiFixtureSleepSettings"
        static let todosDeskFlag = "-PaiFixtureTodosDesk"
        static let todosAddFlag = "-PaiFixtureTodosAdd"
        static let todosExpandFlag = "-PaiFixtureTodosExpand"
        static let todosOpenFlag = "-PaiFixtureTodosOpen"
        static let todosSearchFlag = "-PaiFixtureTodosSearch"
        static let todosArrangeFlag = "-PaiFixtureTodosArrange"
        static let todosDescribeFlag = "-PaiFixtureTodosDescribe"
        static let todosWhenFlag = "-PaiFixtureTodosWhen"
        static let todosTickFlag = "-PaiFixtureTodosTick"
        static let todosSubtaskFlag = "-PaiFixtureTodosSubtask"
        static let todosSwitchFlag = "-PaiFixtureTodosSwitch"
        static let todosSettingsFlag = "-PaiFixtureTodosSettings"

        /// What the debug bridge can change while the app runs: the offline switch, and whether
        /// the one-shot conflict has been served.
        private final class RuntimeState: @unchecked Sendable {
            let lock = NSLock()
            var offlineOverride: Bool?
            var conflictServed = false
        }

        private static let runtime = RuntimeState()

        /// The session id every session-scoped fixture route answers under, regardless of which
        /// id the request actually named — fixed so a screenshot workflow can always ask for this
        /// one id without first discovering which session fixture mode decided to use.
        public static let sessionID = "305df4d3-1554-4fc3-be04-39a354a9e619"

        /// The subagent of ``sessionID`` in the corpus (`PaiFixtures.sessionSubagent`), what
        /// `-PaiFixtureRoute subagentSession` opens.
        public static let subagentSessionID = Route.fixtureSubagentSessionID

        /// Whether `-PaiFixtureNotesFilterFocused` was passed — how the Mac workflow reaches the
        /// note index with its search field actually focused, a state a plain launch cannot reach.
        public static func focusesNotesFilter(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(notesFilterFocusFlag)
        }

        /// The text `-PaiFixtureDraftText <text>` puts in the fixture session's composer, so a
        /// screenshot can show what the composer draws for a given draft (the `/compact` chip, a
        /// skill mention). Absent leaves the corpus's own draft.
        public static func requestedDraftText(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: draftTextFlag, in: arguments)
        }

        /// The session type `-PaiFixtureNewSessionType <id>` chooses on the new-session screen, as
        /// the draft a previous visit left would.
        public static func requestedNewSessionType(arguments: [String] = ProcessInfo.processInfo.arguments)
            -> String?
        {
            value(for: newSessionTypeFlag, in: arguments)
        }

        /// What `-PaiFixturePlayback <state>` puts the player in on the fixture session: `on` (the
        /// mini bar, nothing playing), `paused` (a reply in hand), `sheet` (that, with the full view
        /// open) or `error` (a reply the backend refused).
        public static func requestedPlayback(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: playbackFlag, in: arguments)
        }

        /// Whether the process was launched with `-PaiFixtureMode`.
        public static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(modeFlag)
        }

        /// The screen name passed via `-PaiFixtureRoute <name>`, if any. Absent means "start on
        /// the root screen" — the session list needs no route to reach.
        public static func requestedRouteName(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: routeFlag, in: arguments)
        }

        /// Which `GET /api/auth/claude` body to serve — `-PaiFixtureAuthState
        /// signedOut|rejected|loginInProgress`. Absent means the ordinary healthy default, so
        /// every screenshot other than the sign-in banner itself is unaffected by this flag
        /// existing at all — the one state a screen's own fetches otherwise can never reach,
        /// since fixture mode has no live agent to report a real outage from.
        public static func requestedAuthState(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: authStateFlag, in: arguments)
        }

        /// A `MessageKind.rawValue` to open transcript search with, via `-PaiFixtureSearchKind
        /// <kind>` — how the Mac workflow reaches a jump that lands OUTSIDE the loaded tail
        /// window with no device interaction. `boundary` is the kind that reproduces the bug this
        /// exists to prove fixed: the session-start and compaction rows the jump dropdown lists.
        /// Absent means an ordinary open with no search — every other screenshot's behaviour.
        public static func requestedSearchKind(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: searchKindFlag, in: arguments)
        }

        /// A message id to open `-PaiFixtureRoute session` at, via `-PaiFixtureJumpMessage <id>` —
        /// the route a tapped notification produces, so the Mac workflow can drive a deep link
        /// into a transcript that has not loaded yet with no device interaction. Absent, or not
        /// an integer, means an ordinary open.
        public static func requestedJumpMessageID(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
            value(for: jumpMessageFlag, in: arguments).flatMap(Int.init)
        }

        /// Whether `-PaiFixtureOpenImage` was passed — how the Mac workflow reaches
        /// `FilePreviewViewer`, a `.fullScreenCover(item:)` with no `Route` of its own to
        /// launch straight into. Combined with `-PaiFixtureRoute session`, this makes
        /// `SessionDetailView`'s own `.task` fetch the fixture attachment directly and present the
        /// viewer on appear, rather than waiting for a tap on a message row's attachment chip —
        /// which the fixture corpus deliberately places outside the default tail window, so it is
        /// never built by the virtualized transcript at all in an ordinary open.
        public static func opensImageAutomatically(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(openImageFlag)
        }

        /// Whether `-PaiFixtureOpenPdf` was passed — the same route as ``opensImageAutomatically``,
        /// presenting a generated PDF in the viewer instead of the fixture image, so the PDF path
        /// (`PDFPreviewView`) is drawn by a screenshot run.
        public static func opensPdfAutomatically(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(openPdfFlag)
        }

        /// Whether `-PaiFixtureAutoCreateSession` was passed — how the Mac workflow reproduces the
        /// exact navigation race a real "New Session" send button triggers, with no device
        /// interaction: `CreateSessionView` still presented as a sheet, over the same session list
        /// the real flow uses, then pushing `.session(id:)` and dismissing the sheet the way its
        /// own send button does. Bypasses the network round trip a real send makes — fixture mode
        /// has no `POST /sessions` stub — since what this reproduces is the navigation mechanism,
        /// not the creation call.
        public static func autoCreatesSession(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(autoCreateSessionFlag)
        }

        /// Whether `-PaiFixtureSecretPrompt` was passed — the session list then answers with a
        /// session waiting on a gated-secret grant, which is the only way the banner that offers
        /// it can be drawn at all: nothing in fixture mode has a live conversation to raise one.
        /// Absent leaves every other screenshot unaffected, exactly like the auth-state flag.
        public static func showsSecretPrompt(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(secretPromptFlag)
        }

        /// Whether every fixture request fails the way `URLSession` does with no network. Starts
        /// from `-PaiFixtureOffline`; the debug bridge flips it at run time with
        /// ``setOffline(_:)``, which is how a screenshot run takes an offline edit back online.
        public static func isOffline(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            runtime.lock.withLock { runtime.offlineOverride } ?? arguments.contains(offlineFlag)
        }

        public static func setOffline(_ offline: Bool) {
            runtime.lock.withLock { runtime.offlineOverride = offline }
        }

        /// `-PaiFixtureNotesCacheSeeded`: the notes cache starts holding the fixture index, the
        /// fixture note, its inventory and both attachments, as if they had been opened before.
        public static func seedsNotesCache(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(notesCacheSeededFlag)
        }

        /// `-PaiFixtureNotePendingEdit`: the fixture note starts with an edit made offline and not
        /// yet synced.
        public static func seedsNotePendingEdit(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(notePendingEditFlag)
        }

        /// `-PaiFixtureNoteRefusedEdit`: the fixture note starts with an edit the server refused, as
        /// one made to a note deleted elsewhere is — the state behind the editor's failed-save badge
        /// and Settings' "Not saved" list.
        public static func seedsNoteRefusedEdit(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(noteRefusedEditFlag)
        }

        /// `-PaiFixtureScrollTo <name>`: the spot on a long screen to bring into view (the app
        /// target names the spots), because a screenshot shows only what is on screen.
        public static func requestedScrollAnchor(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: scrollAnchorFlag, in: arguments)
        }

        /// `-PaiFixtureWatchKeys create|revoke-ask|revoke`: drives the watch-key rows with no touch
        /// to press them. `create` makes a key, `revoke-ask` asks to revoke the first one,
        /// `revoke` asks and confirms.
        public static func requestedWatchKeyProbe(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: watchKeysFlag, in: arguments)
        }

        /// `-PaiFixtureWeather <state>`: which of `PaiFixtures.weatherStates` the Weather screen
        /// reads. Absent is the showers-approaching answer.
        public static func requestedWeatherState(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: weatherFlag, in: arguments)
        }

        /// `-PaiFixtureTodosDesk bar|split|desk`: the desk state a Todos page opens in.
        public static func requestedTodosDesk(arguments: [String] = ProcessInfo.processInfo.arguments) -> TodoDeskMode?
        {
            value(for: todosDeskFlag, in: arguments).flatMap(TodoDeskMode.init(rawValue:))
        }

        /// `-PaiFixtureTodosAdd <text>`: a Todos page opens its add sheet with this line typed.
        public static func requestedTodosAdd(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: todosAddFlag, in: arguments)
        }

        /// `-PaiFixtureTodosExpand`: a Todos page opens the corpus todo that has subtasks.
        public static func expandsTodosParent(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(todosExpandFlag)
        }

        /// `-PaiFixtureTodosOpen`: a Todos page opens the sheet of the corpus todo with subtasks.
        public static func opensTodosSheet(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(todosOpenFlag)
        }

        /// `-PaiFixtureTodosSearch <text>`: Todos' search opens with this typed.
        public static func requestedTodosSearch(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: todosSearchFlag, in: arguments)
        }

        /// `-PaiFixtureTodosArrange`: the desk opens with its cards in arranging mode.
        public static func arrangesTodosDesk(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(todosArrangeFlag)
        }

        /// `-PaiFixtureTodosDescribe <text>`: a Todos page opens its add sheet in the plain-words
        /// mode with this typed.
        public static func requestedTodosDescribe(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: todosDescribeFlag, in: arguments)
        }

        /// `-PaiFixtureTodosWhen`: the sheet `-PaiFixtureTodosOpen` opens shows its When screen,
        /// with the nudges.
        public static func opensTodosWhen(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(todosWhenFlag)
        }

        /// `-PaiFixtureTodosTick`: a Todos page ticks its first row once it has rows, which shows
        /// the toast with Undo.
        public static func ticksTodosRow(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(todosTickFlag)
        }

        /// `-PaiFixtureTodosSubtask <line>`: the todo sheet's subtask line opens with this typed,
        /// scrolled into view.
        public static func requestedTodosSubtask(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: todosSubtaskFlag, in: arguments)
        }

        /// `-PaiFixtureTodosSwitch <query>`: a Todos page opens its switcher with this typed.
        public static func requestedTodosSwitch(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: todosSwitchFlag, in: arguments)
        }

        /// `-PaiFixtureTodosSettings <section>`: a Todos page opens Todos' settings, at the
        /// section named (`general`, `nudges`, `lists`, `tags`, `views`), or the section list for
        /// `all`.
        public static func requestedTodosSettings(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: todosSettingsFlag, in: arguments)
        }

        /// `-PaiFixtureMe <state>`: which of `PaiFixtures.meStates` the Me routes answer. Absent is the full one.
        public static func requestedMeState(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: meFlag, in: arguments)
        }

        /// `-PaiFixtureMeTab today|days|diary`: the Me screen's opening tab.
        public static func requestedMeTab(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: meTabFlag, in: arguments)
        }

        /// `-PaiFixtureSchedulerSection reminders`: the Scheduler opens on its reminder list.
        public static func requestedSchedulerSection(arguments: [String] = ProcessInfo.processInfo.arguments) -> String?
        {
            value(for: schedulerSectionFlag, in: arguments)
        }

        /// `-PaiFixtureAlarmSheet time|in`: the Alarm screen opens its new-alarm sheet at once, in
        /// the "At time" or the "In" mode.
        public static func requestedAlarmSheet(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: alarmSheetFlag, in: arguments)
        }

        /// `-PaiFixtureSessionFilters hideClosed|machine|both`: the session list starts with
        /// "Hide closed sessions" and/or the second machine chosen.
        public static func requestedSessionFilters(arguments: [String] = ProcessInfo.processInfo.arguments)
            -> String?
        {
            value(for: sessionFiltersFlag, in: arguments)
        }

        /// `-PaiFixtureMeDay <n>`: the 14-day grid opens with the day `n` days before today picked.
        public static func requestedMeDayOffset(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
            value(for: meDayFlag, in: arguments).flatMap { Int($0) }
        }

        /// `-PaiFixtureRole guest`: the corpus answers as a guest signed in, with the guest's settings
        /// schema. Absent is the owner.
        public static func requestedRole(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: roleFlag, in: arguments)
        }

        /// `-PaiFixtureSleep on|configured`: sleep mode is set up with a window and a PIN (1234), and
        /// the clock stands inside the window (`on`) or outside it (`configured`).
        public static func requestedSleep(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: sleepFlag, in: arguments)
        }

        /// `-PaiFixtureSleepSettings`: the Notifications page opens the sleep-mode screen at once.
        public static func opensSleepSettings(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(sleepSettingsFlag)
        }

        /// `-PaiFixtureSettingsCategory <id>`: Settings opens on that category rather than its list.
        public static func requestedSettingsCategory(arguments: [String] = ProcessInfo.processInfo.arguments)
            -> String?
        {
            value(for: settingsCategoryFlag, in: arguments)
        }

        /// `-PaiFixtureQuickMore`: the Quick Actions screen opens its More list at once.
        public static func opensQuickMore(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(quickMoreFlag)
        }

        /// `-PaiFixtureQuickEdit library|addShortcut`: the Quick Actions screen opens its Actions
        /// Library at once, and with `addShortcut` the add sheet over it.
        public static func requestedQuickEdit(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: quickEditFlag, in: arguments)
        }

        /// `-PaiFixtureQuickShortcuts`: three example shortcuts are added to the end of the grid, so
        /// it holds more than fifteen tiles.
        public static func seedsQuickShortcuts(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(quickShortcutsFlag)
        }

        /// `-PaiFixtureMeComposer`: the Me composer opens at once over a seeded draft.
        public static func opensMeComposer(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(meComposerFlag)
        }

        /// `-PaiFixtureCameraImport`: the Camera Import screen runs at once over
        /// ``CameraImportFixture``'s folder and library instead of the real ones.
        public static func runsCameraImport(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(cameraImportFlag)
        }

        /// `-PaiFixtureNotificationSource only|exclude`: the notification centre opens filtered to
        /// scheduled-task notifications or to the rest. Absent, or any other value, is no filter.
        public static func requestedNotificationSource(
            arguments: [String] = ProcessInfo.processInfo.arguments
        ) -> NotificationSource? {
            value(for: notificationSourceFlag, in: arguments).map { NotificationSource(queryValue: $0) }
        }

        /// `-PaiFixtureNoteConflict`: the first save of a note answers 409 with a different body,
        /// the way a note edited elsewhere does; every later save succeeds. True exactly once.
        static func takeNoteConflict(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            guard arguments.contains(noteConflictFlag) else { return false }
            return runtime.lock.withLock {
                guard !runtime.conflictServed else { return false }
                runtime.conflictServed = true
                return true
            }
        }

        /// For tests: forget what the bridge set and whether the conflict was served.
        static func resetRuntimeState() {
            runtime.lock.withLock {
                runtime.offlineOverride = nil
                runtime.conflictServed = false
            }
        }

        static func value(for flag: String, in arguments: [String]) -> String? {
            guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }
            let valueIndex = arguments.index(after: flagIndex)
            guard valueIndex < arguments.count else { return nil }
            return arguments[valueIndex]
        }
    }

#endif
