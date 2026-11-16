import PAIKit
import SwiftUI

/// The Alarm app: alarms ringing right now pinned on top with Dismiss, the armed ones under
/// them, "+" to arm another and a gear for how a ring behaves. The server owns every state; the
/// screen re-reads it every couple of seconds while it is visible.
struct AlarmView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @State private var store: AlarmStore?
    @State private var isAdding = false
    @State private var isConfiguring = false

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Alarm")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isConfiguring = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Ring settings")
                .accessibilityIdentifier("alarm-settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New alarm")
                .accessibilityIdentifier("alarm-add")
            }
        }
        .sheet(isPresented: $isAdding) {
            if let store { NewAlarmSheet(store: store) }
        }
        .sheet(isPresented: $isConfiguring) {
            AlarmRingSettingsSheet(store: settings.userSettings)
        }
        .task {
            let current: AlarmStore
            if let store {
                current = store
            } else if let client = environment.connection?.apiClient {
                current = AlarmStore(api: client)
                store = current
            } else {
                return
            }
            await settings.userSettings.load()
            await current.poll()
        }
        .onChange(of: store?.errorMessage) { _, message in
            if let message { toasts.show(message, kind: .error) }
        }
        .fixtureFact("alarmRinging", "\(store?.ringing.count ?? -1)")
        .fixtureFact("alarmArmed", "\(store?.alarms.count ?? -1)")
    }

    @ViewBuilder
    private func content(_ store: AlarmStore) -> some View {
        if store.isLoading && store.alarms.isEmpty && store.ringing.isEmpty {
            ProgressView()
        } else if store.alarms.isEmpty && store.ringing.isEmpty {
            Text("No alarms. Tap + to set one.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        } else {
            List {
                if !store.ringing.isEmpty {
                    Section {
                        ForEach(store.ringing) { alarm in
                            RingingRow(alarm: alarm) { Task { await store.dismiss(alarm) } }
                        }
                        if store.ringing.count > 1 {
                            Button("Dismiss all", role: .destructive) { Task { await store.dismissAll() } }
                                .accessibilityIdentifier("alarm-dismiss-all")
                        }
                    } header: {
                        Text("Ringing")
                    }
                }
                if !store.alarms.isEmpty {
                    Section {
                        ForEach(store.alarms) { alarm in
                            ArmedRow(alarm: alarm)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { Task { await store.delete(alarm) } }
                                }
                        }
                    } header: {
                        Text("Upcoming")
                    }
                }
            }
            .refreshable { await store.load() }
        }
    }
}

private struct RingingRow: View {
    let alarm: RingingAlarm
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Text(AlarmTime.title(alarm.name))
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
            Spacer()
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("alarm-dismiss-\(alarm.id)")
        }
        .padding(.vertical, 4)
    }
}

private struct ArmedRow: View {
    let alarm: Alarm

    var body: some View {
        HStack {
            Text(AlarmTime.title(alarm.name))
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            Spacer()
            if let date = alarm.fireDate {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ClockTime.string(date))
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    Text(dayLabel(date))
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
            }
        }
        .accessibilityIdentifier("alarm-row-\(alarm.id)")
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }
}

/// The hour and minute wheel and an optional name. The date is not asked: the next time the
/// clock shows it is what the alarm fires at.
private struct NewAlarmSheet: View {
    let store: AlarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()
    @State private var name = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, ClockTime.pickerLocale)
                    .accessibilityIdentifier("alarm-time")
                TextField("Name (optional)", text: $name)
                    .accessibilityIdentifier("alarm-name")
            }
            .navigationTitle("New alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("alarm-save")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        guard let hour = parts.hour, let minute = parts.minute else { return }
        isSaving = true
        Task {
            if await store.add(hour: hour, minute: minute, name: name) { dismiss() }
            isSaving = false
        }
    }
}

/// How a ring behaves, stored with the person's other settings so every device and the watch
/// share it. Each choice includes the value currently stored, so one set elsewhere stays visible.
private struct AlarmRingSettingsSheet: View {
    let store: UserSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    private static let intervals = [2, 3, 5, 10, 15, 30, 60]
    private static let durations = [10, 30, 60, 120, 300, 600]

    var body: some View {
        NavigationStack {
            Form {
                if let settings = store.settings {
                    Section {
                        Picker(
                            "Push every",
                            selection: binding(settings.alarmRingIntervalS) {
                                UserSettingsPatch(alarmRingIntervalS: $0)
                            }
                        ) {
                            ForEach(choices(Self.intervals, including: settings.alarmRingIntervalS), id: \.self) {
                                Text("\($0) s").tag($0)
                            }
                        }
                        .accessibilityIdentifier("alarm-interval")
                        Picker(
                            "Ring for",
                            selection: binding(settings.alarmRingDurationS) {
                                UserSettingsPatch(alarmRingDurationS: $0)
                            }
                        ) {
                            ForEach(choices(Self.durations, including: settings.alarmRingDurationS), id: \.self) {
                                Text(durationText($0)).tag($0)
                            }
                        }
                        .accessibilityIdentifier("alarm-duration")
                    } footer: {
                        Text("A ringing alarm sends a push at this interval until you dismiss it or the time is up.")
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Ring settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func choices(_ base: [Int], including current: Int) -> [Int] {
        base.contains(current) ? base : (base + [current]).sorted()
    }

    private func durationText(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    private func binding(_ current: Int, patch: @escaping (Int) -> UserSettingsPatch) -> Binding<Int> {
        Binding(
            get: { current },
            set: { value in
                Task {
                    if !(await store.update(patch(value))), let message = store.errorMessage {
                        toasts.show(message, kind: .error)
                    }
                }
            })
    }
}
