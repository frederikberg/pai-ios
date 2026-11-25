import PAIKit
import SwiftUI

/// PAI's own scheduler: every task, newest first, with a way to create one. Swift port of the
/// list half of `SchedulerApp.tsx` — the create/edit form itself is `TaskEditorView`, its own
/// pushed page under `.schedulerTask(id:)`.
struct SchedulerListView: View {
    /// Tasks and reminders share the screen: both start something without a person, one by a
    /// schedule and a session, the other by a place, an event or a script.
    private enum ListKind: String, CaseIterable {
        case tasks = "Tasks"
        case reminders = "Reminders"
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var store: SchedulerListStore?
    @State private var reminders: ReminderListStore?
    @State private var section = ListKind.tasks

    private var offersReminders: Bool { environment.connection?.me.capabilities.canOpenReminders == true }

    var body: some View {
        VStack(spacing: 0) {
            if offersReminders {
                Picker("Section", selection: $section) {
                    ForEach(ListKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("scheduler-section")
            }
            Group {
                if section == .reminders, offersReminders {
                    if let reminders {
                        ReminderListContent(store: reminders)
                    } else {
                        ProgressView()
                    }
                } else if let store {
                    content(store)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Scheduler")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if section == .tasks {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        environment.router.push(.schedulerTask(id: nil))
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("new-scheduled-task")
                }
            }
        }
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            #if DEBUG
                if PaiFixtureLaunch.requestedSchedulerSection() == "reminders" { section = .reminders }
            #endif
            let newStore = SchedulerListStore(api: client)
            store = newStore
            let newReminders = ReminderListStore(api: client)
            reminders = newReminders
            async let tasks: Void = newStore.load()
            async let wakes: Void = newStore.loadWakes()
            async let reminderRows: Void = loadReminders(newReminders)
            _ = await (tasks, wakes, reminderRows)
        }
        // Back from a reminder's detail, which may have paused or deleted it.
        .onAppear {
            guard let reminders else { return }
            Task { await reminders.load() }
        }
    }

    private func loadReminders(_ store: ReminderListStore) async {
        guard offersReminders else { return }
        await store.load()
    }

    @ViewBuilder
    private func content(_ store: SchedulerListStore) -> some View {
        if store.isLoading && store.tasks.isEmpty {
            ProgressView()
        } else if let error = store.errorMessage, store.tasks.isEmpty {
            VStack(spacing: 8) {
                Text(error)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if store.tasks.isEmpty && store.wakes.isEmpty {
            VStack(spacing: 4) {
                Text("No scheduled tasks yet.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Text("A task pairs a schedule with an optional script that decides whether to actually run.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else {
            List {
                ForEach(store.tasks) { task in
                    Button {
                        environment.router.push(.schedulerTask(id: task.id))
                    } label: {
                        SchedulerTaskRow(task: task)
                    }
                    .buttonStyle(.plain)
                }
                if !store.wakes.isEmpty || store.wakeErrorMessage != nil {
                    Section("Mailbox wake-ups") {
                        if let error = store.wakeErrorMessage {
                            Text(error)
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.Semantic.errorText)
                        }
                        ForEach(store.wakes) { wake in
                            InboxWakeRow(wake: wake) {
                                Task { await store.removeWake(id: wake.id) }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable {
                async let tasks: Void = store.load()
                async let wakes: Void = store.loadWakes()
                _ = await (tasks, wakes)
            }
        }
    }
}

private struct SchedulerTaskRow: View {
    let task: ScheduledTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(task.name)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(task.enabled ? PaiPalette.Semantic.textPrimary : PaiPalette.Semantic.textFaint)
                    .lineLimit(1)
                if SchedulerTaskDisplay.isStale(task, nowMs: Int(Date().timeIntervalSince1970 * 1000)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PaiPalette.Semantic.warningText)
                        .accessibilityLabel("No successful run in a while")
                }
                Spacer()
                statusPill
            }
            HStack(spacing: 6) {
                Text(task.environment)
                Text("·")
                Text(SchedulerTaskDisplay.whenLabel(task))
                if task.hasGate {
                    Image(systemName: "arrow.triangle.branch")
                }
                if !task.enabled {
                    Spacer()
                    Text("disabled")
                }
            }
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            if let wake = SchedulerTaskDisplay.wakeLabel(task) {
                Text(wake)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("scheduler-task-\(task.id)")
    }

    private var statusPill: some View {
        let (label, color): (String, Color) = {
            switch SchedulerTaskDisplay.lastRunStatus(task) {
            case .never: return ("never fired", PaiPalette.Semantic.textFaint)
            case .ok: return ("ok", PaiPalette.green500)
            case .attention: return ("attention", PaiPalette.Semantic.warningText)
            case .stopped: return ("stopped", PaiPalette.Semantic.errorText)
            }
        }()
        return Text(label)
            .font(PaiTypography.captionEmphasized.font)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// One session registered to be woken by mail: which session, inbox and pattern, how often it may
/// wake, what is waiting, with a way into the session and a confirmed removal.
private struct InboxWakeRow: View {
    @Environment(AppEnvironment.self) private var environment
    let wake: InboxWake
    let onRemove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(wake.sessionTitle ?? "Untitled session")
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(wake.inbox)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            Text(patternLabel)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Text(detailLabel)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Text(wake.prompt)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textFaint)
                .lineLimit(2)
            HStack(spacing: 16) {
                Spacer()
                Button("Open session") {
                    environment.router.push(.session(id: wake.sessionId))
                }
                .buttonStyle(.borderless)
                Button("Remove", role: .destructive) { confirmingRemoval = true }
                    .buttonStyle(.borderless)
            }
            .font(PaiTypography.caption.font)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("inbox-wake-\(wake.id)")
        .confirmationDialog("Remove this wake-up?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove wake-up", role: .destructive, action: onRemove)
        } message: {
            Text("The session is no longer woken by this mail.")
        }
    }

    private var patternLabel: String {
        let subject = "subject /\(wake.subjectPattern)/"
        guard let sender = wake.senderPattern else { return subject }
        return subject + " · sender /\(sender)/"
    }

    private var detailLabel: String {
        let every = "every \(SchedulerTaskDisplay.debounceLabel(minutes: wake.debounceMinutes)) at most"
        return [every, SchedulerTaskDisplay.wakeLastWokenLabel(wake), SchedulerTaskDisplay.wakeWaitingLabel(wake)]
            .joined(separator: " · ")
    }
}
