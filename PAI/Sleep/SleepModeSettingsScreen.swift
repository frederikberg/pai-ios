import PAIKit
import SwiftUI

/// Where sleep mode is turned on, and its window and PIN changed. Everything that changes it asks
/// for the PIN, so it stays a decision made in the daytime. It is a convenience of this iPhone, not
/// security: anyone with the phone unlocked and a reinstall can undo it.
struct SleepModeSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts

    @State private var creating: PinPurpose?
    @State private var asking: PinPurpose?
    /// What to present once the PIN sheet has finished leaving: a sheet presented from behind a
    /// dismissing one is dropped.
    @State private var afterAsking: PinPurpose?
    /// What a PIN just verified lets this screen do until it is left: the window pickers.
    @State private var editingWindow: SleepWindow?
    @State private var verifiedPin = ""
    @State private var from = SleepWindow.standard.startMinute
    @State private var to = SleepWindow.standard.endMinute

    private var sleep: SleepModeStore { environment.sleepMode }

    private enum PinPurpose: Identifiable {
        case enable, changeWindow, changePin, changePinNew(old: String), disable
        var id: String {
            switch self {
            case .enable: "enable"
            case .changeWindow: "window"
            case .changePin: "pin"
            case .changePinNew: "pin-new"
            case .disable: "disable"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                if sleep.isEnabled {
                    LabeledContent("Window", value: sleep.settings.window.label)
                        .accessibilityIdentifier("sleep-window")
                    if editingWindow != nil {
                        windowPickers
                    } else {
                        Button("Change window…") { asking = .changeWindow }
                            .accessibilityIdentifier("sleep-change-window")
                    }
                    Button("Change PIN…") { asking = .changePin }
                        .accessibilityIdentifier("sleep-change-pin")
                    Button("Turn off…", role: .destructive) { asking = .disable }
                        .accessibilityIdentifier("sleep-turn-off")
                } else {
                    windowPickers
                    Button("Turn on…") { creating = .enable }
                        .accessibilityIdentifier("sleep-turn-on")
                }
            } header: {
                Text("Sleep mode · \(SettingsScope.thisDevice.label)")
            } footer: {
                Text(
                    "From the start time to the end time, every day, the sessions and everything about the agents are put away on this iPhone: no push reaches it, and its screen is the list of the other apps. A recording into a session ends when the window begins. Alarms still ring. A PIN stands in the way of changing it on impulse; it is no security."
                )
            }
        }
        .paiListBackground()
        .navigationTitle("Sleep mode")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { syncPickers() }
        .onDisappear { verifiedPin = "" }
        .sheet(
            item: $asking,
            onDismiss: {
                creating = afterAsking
                afterAsking = nil
            }
        ) { purpose in
            askSheet(purpose)
        }
        .sheet(item: $creating) { purpose in createSheet(purpose) }
        .accessibilityIdentifier("sleep-mode-settings")
        .fixtureFact("sleepModeEnabled", sleep.isEnabled ? "on" : "off")
    }

    private var windowPickers: some View {
        Group {
            DatePicker("From", selection: binding($from), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("sleep-from")
            DatePicker("To", selection: binding($to), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("sleep-to")
            if sleep.isEnabled {
                Button("Save window") { saveWindow() }
                    .disabled(SleepWindow(startMinute: from, endMinute: to) == nil)
                    .accessibilityIdentifier("sleep-save-window")
            }
            if SleepWindow(startMinute: from, endMinute: to) == nil {
                Text("The window cannot start and end at the same time.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
    }

    @ViewBuilder
    private func askSheet(_ purpose: PinPurpose) -> some View {
        switch purpose {
        case .changeWindow:
            PinEntrySheet(
                title: "Change window", check: { sleep.check($0) },
                onAccepted: { pin in
                    verifiedPin = pin
                    syncPickers()
                    editingWindow = sleep.settings.window
                })
        case .changePin:
            PinEntrySheet(
                title: "Change PIN", prompt: "Enter your current PIN", check: { sleep.check($0) },
                onAccepted: { old in afterAsking = .changePinNew(old: old) })
        case .disable:
            PinEntrySheet(
                title: "Turn off sleep mode", check: { sleep.check($0) },
                onAccepted: { pin in
                    if sleep.disable(pin: pin) != .accepted {
                        toasts.show("Could not turn sleep mode off", kind: .error)
                    }
                    editingWindow = nil
                })
        case .enable, .changePinNew:
            EmptyView()
        }
    }

    @ViewBuilder
    private func createSheet(_ purpose: PinPurpose) -> some View {
        switch purpose {
        case .enable:
            PinCreateSheet(title: "Turn on sleep mode") { pin in
                guard let window = SleepWindow(startMinute: from, endMinute: to), sleep.enable(window: window, pin: pin)
                else {
                    toasts.show("Choose a window with a different start and end", kind: .error)
                    return
                }
            }
        case .changePinNew(let old):
            PinCreateSheet(title: "New PIN") { new in
                if sleep.changePin(from: old, to: new) != .accepted {
                    toasts.show("Could not change the PIN", kind: .error)
                }
            }
        case .changeWindow, .changePin, .disable:
            EmptyView()
        }
    }

    private func saveWindow() {
        guard let window = SleepWindow(startMinute: from, endMinute: to) else { return }
        if sleep.setWindow(window, pin: verifiedPin) == .accepted {
            editingWindow = nil
        } else {
            toasts.show("Could not change the window", kind: .error)
        }
    }

    private func syncPickers() {
        guard sleep.isEnabled else { return }
        from = sleep.settings.window.startMinute
        to = sleep.settings.window.endMinute
    }

    /// A time picker's date for a minute of the day, today in this phone's calendar.
    private func binding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date())
                    ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }
}
