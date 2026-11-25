import PAIKit
import SwiftUI

/// The Scheduler's reminder list: what the owner asked to be told, by place, event or script. An
/// agent writes a reminder from a sentence, so there is no way to create one here.
struct ReminderListContent: View {
    @Environment(AppEnvironment.self) private var environment
    let store: ReminderListStore

    var body: some View {
        if store.isLoading && store.reminders.isEmpty {
            ProgressView()
        } else if let error = store.errorMessage, store.reminders.isEmpty {
            VStack(spacing: 8) {
                Text(error)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if store.reminders.isEmpty {
            VStack(spacing: 4) {
                Text("No reminders yet.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Text("Ask a session to remind you when you arrive somewhere, when a door opens or when a page changes.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else {
            List {
                ForEach(store.reminders) { reminder in
                    Button {
                        environment.router.push(.reminder(id: reminder.id))
                    } label: {
                        ReminderRow(reminder: reminder)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .refreshable { await store.load() }
            .fixtureFact("reminderRows", store.reminders.map(\.name).joined(separator: ","))
        }
    }
}

private struct ReminderRow: View {
    let reminder: Reminder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(reminder.title)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(
                        reminder.state == .paused ? PaiPalette.Semantic.textFaint : PaiPalette.Semantic.textPrimary
                    )
                    .lineLimit(1)
                Spacer()
                ReminderStatePill(reminder: reminder)
            }
            Text(ReminderDisplay.summaryLine(reminder))
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .lineLimit(2)
            if let activity = ReminderDisplay.activityLine(reminder) {
                Text(activity)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("reminder-\(reminder.id)")
    }
}

private struct ReminderStatePill: View {
    let reminder: Reminder

    var body: some View {
        let color = Self.color(ReminderDisplay.stateTone(reminder))
        Text(ReminderDisplay.stateLabel(reminder))
            .font(PaiTypography.captionEmphasized.font)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private static func color(_ tone: ReminderDisplay.Tone) -> Color {
        switch tone {
        case .ok: PaiPalette.green500
        case .muted: PaiPalette.Semantic.textFaint
        case .warning: PaiPalette.Semantic.warningText
        case .error: PaiPalette.Semantic.errorText
        }
    }
}

/// One reminder: what wakes it, what it says, how it has been doing, its script read-only and its
/// history, with Test, Pause or Resume, and Delete.
struct ReminderDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    let reminderId: String
    @State private var store: ReminderDetailStore?
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(store?.reminder?.name ?? "Reminder")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = ReminderDetailStore(id: reminderId, api: client)
            store = newStore
            await newStore.load()
        }
        .confirmationDialog("Delete this reminder?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await store?.delete()
                    if store?.isDeleted == true { environment.router.pop() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its history goes with it; the notifications it sent stay.")
        }
        .onChange(of: store?.errorMessage) { _, message in
            if let message, store?.reminder != nil { toasts.show(message, kind: .error) }
        }
    }

    @ViewBuilder
    private func content(_ store: ReminderDetailStore) -> some View {
        if store.isLoading && store.reminder == nil {
            ProgressView()
        } else if store.isGone {
            Text("This reminder no longer exists.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let reminder = store.reminder {
            List {
                header(reminder)
                if let result = store.testResult { testSection(result, store: store) }
                actions(store, reminder: reminder)
                if let source = reminder.scriptSource { scriptSection(source, runtime: reminder.scriptRuntime) }
                if let events = reminder.events, !events.isEmpty { historySection(events) }
            }
            .listStyle(.insetGrouped)
            .fixtureFact("reminderDetail", "\(reminder.name) \(ReminderDisplay.stateLabel(reminder))")
        } else if let error = store.errorMessage {
            VStack(spacing: 8) {
                Text(error)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
    }

    private func header(_ reminder: Reminder) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(reminder.title)
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    Spacer()
                    ReminderStatePill(reminder: reminder)
                }
                if let body = reminder.body, !body.isEmpty {
                    Text(body)
                        .font(PaiTypography.body.font)
                        .foregroundStyle(PaiPalette.Semantic.textSecondary)
                }
                Text(ReminderDisplay.summaryLine(reminder))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                ForEach(ReminderDisplay.limitLines(reminder), id: \.self) { line in
                    Text(line).font(PaiTypography.caption.font).foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                if let activity = ReminderDisplay.activityLine(reminder) {
                    Text(activity).font(PaiTypography.caption.font).foregroundStyle(PaiPalette.Semantic.textFaint)
                }
                if let expiry = ReminderDisplay.expiryLine(reminder) {
                    Text(expiry).font(PaiTypography.caption.font).foregroundStyle(PaiPalette.Semantic.textFaint)
                }
                if reminder.consecutiveFailures > 0 {
                    Text("\(reminder.consecutiveFailures) failed checks in a row")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func actions(_ store: ReminderDetailStore, reminder: Reminder) -> some View {
        Section {
            Button("Test") { Task { await store.test(notify: false) } }
                .accessibilityIdentifier("reminder-test")
            Button("Test and send a notification") { Task { await store.test(notify: true) } }
                .accessibilityIdentifier("reminder-test-notify")
            if store.canResume {
                Button(reminder.state == .failing ? "Resume checking" : "Resume") {
                    Task { await store.resume() }
                }
                .accessibilityIdentifier("reminder-resume")
            }
            if store.canPause {
                Button("Pause") { Task { await store.pause() } }
                    .accessibilityIdentifier("reminder-pause")
            }
            Button("Delete", role: .destructive) { confirmingDelete = true }
                .accessibilityIdentifier("reminder-delete")
        }
        .disabled(store.isWorking)
    }

    private func testSection(_ result: ReminderTestResult, store: ReminderDetailStore) -> some View {
        Section("Last test") {
            Text(ReminderDisplay.testSummary(result))
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            if !result.stdoutTail.isEmpty {
                Text(result.stdoutTail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if !result.stderrTail.isEmpty {
                Text(result.stderrTail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
            Button("Dismiss") { store.dismissTestResult() }
        }
    }

    private func scriptHeader(_ runtime: String?) -> String {
        guard let runtime else { return "Script" }
        return "Script · \(runtime)"
    }

    private func scriptSection(_ source: String, runtime: String?) -> some View {
        Section(scriptHeader(runtime)) {
            ScrollView(.horizontal) {
                Text(source)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func historySection(_ events: [ReminderEvent]) -> some View {
        Section("History") {
            ForEach(events) { event in
                Text(ReminderDisplay.eventLine(event))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
    }
}
