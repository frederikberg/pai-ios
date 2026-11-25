import PAIKit
import SwiftUI

/// The Alarm app: alarms ringing right now pinned on top with Dismiss, the armed ones under
/// them, "+" (or a tap on the empty area) to arm another and a gear for how a ring behaves. The
/// server owns every state; the screen re-reads it every couple of seconds while it is visible.
struct AlarmView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @State private var store: AlarmStore?
    @State private var isAdding = false
    @State private var isConfiguring = false
    /// The room under the last row, drawn as one more row so a tap there is a tap in the list's
    /// own scroll view and pulling down to refresh still works from it.
    @State private var blankHeight: CGFloat = 0
    #if DEBUG
        @State private var fixtureEntryMode: AlarmEntryMode?
    #endif

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
            if let store { NewAlarmSheet(store: store, initialMode: initialEntryMode) }
        }
        .sheet(isPresented: $isConfiguring) {
            AlarmRingSettingsSheet(store: settings.registry)
        }
        .task {
            let current: AlarmStore
            if let store {
                current = store
            } else if let client = environment.connection?.apiClient {
                current = AlarmStore(api: client)
                store = current
                #if DEBUG
                    if PaiFixtureLaunch.isEnabled(), let named = PaiFixtureLaunch.requestedAlarmSheet() {
                        fixtureEntryMode = named == "in" ? .relative : .time
                        isAdding = true
                    }
                #endif
            } else {
                return
            }
            await settings.registry.load()
            await current.poll()
        }
        .onChange(of: store?.errorMessage) { _, message in
            if let message { toasts.show(message, kind: .error) }
        }
        .fixtureFact("alarmRinging", "\(store?.ringing.count ?? -1)")
        .fixtureFact("alarmArmed", "\(store?.alarms.count ?? -1)")
    }

    private var initialEntryMode: AlarmEntryMode {
        #if DEBUG
            if let fixtureEntryMode { return fixtureEntryMode }
        #endif
        return .time
    }

    @ViewBuilder
    private func content(_ store: AlarmStore) -> some View {
        if store.isLoading && store.alarms.isEmpty && store.ringing.isEmpty {
            ProgressView()
        } else if store.alarms.isEmpty && store.ringing.isEmpty {
            Text("No alarms. Tap anywhere to set one.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
                .contentShape(Rectangle())
                .onTapGesture { isAdding = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("alarm-empty")
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
                blankRow
            }
            .refreshable { await store.load() }
            .onScrollGeometryChange(for: AlarmListSpace.self) { geometry in
                AlarmListSpace(
                    visibleHeight: geometry.containerSize.height - geometry.contentInsets.top
                        - geometry.contentInsets.bottom,
                    contentHeight: geometry.contentSize.height)
            } action: { _, space in
                let blank = space.blank(excluding: blankHeight)
                if abs(blank - blankHeight) > 0.5 { blankHeight = blank }
            }
            .fixtureFact("alarmBlank", "\(Int(blankHeight))")
        }
    }

    /// What fills the list's remaining height: invisible, tappable, and hidden from VoiceOver,
    /// which has the "+" button.
    private var blankRow: some View {
        Color.clear
            .frame(height: blankHeight)
            .contentShape(Rectangle())
            .onTapGesture { isAdding = true }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
            .accessibilityIdentifier("alarm-blank")
    }
}

/// The two heights the blank row is derived from, read from the list's scroll view.
private struct AlarmListSpace: Equatable {
    let visibleHeight: CGFloat
    let contentHeight: CGFloat

    /// The height the blank row needs so rows plus blank exactly fill the view; the row's own
    /// current height is part of `contentHeight` and comes off first.
    func blank(excluding current: CGFloat) -> CGFloat {
        max(0, visibleHeight - (contentHeight - current))
    }
}

/// How the new-alarm sheet asks for the fire time.
private enum AlarmEntryMode: String, CaseIterable, Identifiable {
    case time
    case relative

    var id: String { rawValue }

    var label: String {
        switch self {
        case .time: "At time"
        case .relative: "In"
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
                    Text(ClockTime.stringShowingSeconds(date))
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

/// The fire time and an optional name. "At time" is the hour and minute wheel: the date is not
/// asked, the next time the clock shows it is what the alarm fires at. "In" is hours, minutes
/// and seconds from the moment Save is pressed.
private struct NewAlarmSheet: View {
    let store: AlarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AlarmEntryMode
    @State private var time = Date()
    @State private var hours = 0
    @State private var minutes = 0
    @State private var seconds = 0
    @State private var name = ""
    @State private var isSaving = false

    init(store: AlarmStore, initialMode: AlarmEntryMode) {
        self.store = store
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .time:
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .environment(\.locale, ClockTime.pickerLocale)
                        .accessibilityIdentifier("alarm-time")
                case .relative:
                    HStack(spacing: 0) {
                        wheel("hours", 0..<24, $hours, id: "alarm-in-hours")
                        wheel("minutes", 0..<60, $minutes, id: "alarm-in-minutes")
                        wheel("seconds", 0..<60, $seconds, id: "alarm-in-seconds")
                    }
                }
                TextField("Name (optional)", text: $name)
                    .accessibilityIdentifier("alarm-name")
            }
            .navigationTitle("New alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Entry", selection: $mode) {
                        ForEach(AlarmEntryMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    .accessibilityIdentifier("alarm-mode")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || (mode == .relative && hours + minutes + seconds == 0))
                        .accessibilityIdentifier("alarm-save")
                }
            }
        }
        .presentationDetents([.medium])
        .fixtureFact("alarmSheetMode", mode.rawValue)
    }

    /// One wheel under its unit. Clipped and composited so neighbouring wheels in a form row
    /// do not take each other's touches.
    private func wheel(_ unit: String, _ range: Range<Int>, _ value: Binding<Int>, id: String) -> some View {
        VStack(spacing: 0) {
            Text(unit)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Picker(unit, selection: value) {
                ForEach(range, id: \.self) { number in
                    Text(unit == "hours" ? "\(number)" : String(format: "%02d", number))
                        .monospacedDigit()
                        .tag(number)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .compositingGroup()
            .clipped()
            .accessibilityIdentifier(id)
        }
        .frame(maxWidth: .infinity)
    }

    private func save() {
        isSaving = true
        Task {
            let saved: Bool
            switch mode {
            case .time:
                let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                if let hour = parts.hour, let minute = parts.minute {
                    saved = await store.add(hour: hour, minute: minute, name: name)
                } else {
                    saved = false
                }
            case .relative:
                saved = await store.add(hours: hours, minutes: minutes, seconds: seconds, name: name)
            }
            if saved { dismiss() }
            isSaving = false
        }
    }
}

/// How a ring behaves, stored with the person's other settings so every device and the watch
/// share it. Each choice includes the value currently stored, so one set elsewhere stays visible.
private struct AlarmRingSettingsSheet: View {
    let store: SettingsRegistryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    private static let intervals = [2, 3, 5, 10, 15, 30, 60]
    private static let durations = [10, 30, 60, 120, 300, 600]

    var body: some View {
        NavigationStack {
            Form {
                if let interval = store.alarmRingIntervalS, let duration = store.alarmRingDurationS {
                    Section {
                        Picker("Push every", selection: binding(interval, key: "alarm_ring_interval_s")) {
                            ForEach(choices(Self.intervals, including: interval), id: \.self) {
                                Text("\($0) s").tag($0)
                            }
                        }
                        .accessibilityIdentifier("alarm-interval")
                        Picker("Ring for", selection: binding(duration, key: "alarm_ring_duration_s")) {
                            ForEach(choices(Self.durations, including: duration), id: \.self) {
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

    private func binding(_ current: Int, key: String) -> Binding<Int> {
        Binding(
            get: { current },
            set: { value in
                Task {
                    if !(await store.updatePerson([key: .whole(value)])), let message = store.errorMessage {
                        toasts.show(message, kind: .error)
                    }
                }
            })
    }
}
