import PAIKit
import SwiftUI

/// What reaches the person, and where. The inbox keeps everything whatever is chosen here.
///
/// Three layers, each with its own scope tag: what the person wants (registry switches, the same on
/// every device), what this iPhone does with a push (on or off, paused for a while, the alarm
/// switch, and the sleep window), and the person's other devices.
struct NotificationsSections: View {
    let settings: SettingsStore
    /// Opens the sleep-mode screen from a launch argument; always `false` in a Release build.
    @State private var fixtureSleepSettings = false

    var body: some View {
        RegistryPlaceholder(store: settings.registry)
        ScopedSection(
            title: "What reaches you", scope: .synced,
            footer: footer
        ) {
            RegistryRows(
                store: settings.registry,
                keys: ["push_alerts", "mail_alerts", "push_agent_messages", "mail_from_agents", "mail_address"])
        }
        ThisPhoneDeliverySection(settings: settings)
        Section {
            NavigationLink {
                SleepModeSettingsScreen()
            } label: {
                SleepModeRowLabel()
            }
            .accessibilityIdentifier("open-sleep-mode")
        } header: {
            Text("Sleep mode · \(SettingsScope.thisDevice.label)")
        } footer: {
            Text(
                "Puts the sessions away on this iPhone and holds back every push except alarms, for a window each day, guarded by a PIN."
            )
        }
        .navigationDestination(isPresented: $fixtureSleepSettings) { SleepModeSettingsScreen() }
        .task {
            #if DEBUG
                if PaiFixtureLaunch.isEnabled(), PaiFixtureLaunch.opensSleepSettings() { fixtureSleepSettings = true }
            #endif
        }
        OtherDevicesSection(store: settings.pushDevices)
    }

    private var footer: String {
        var text = "Everything is always kept in Notifications. Push and mail are only how it also reaches you."
        if NotificationMatrix.reachesNoDevice(person: settings.registry.person) {
            text += " No push reaches any of your devices."
        }
        return text
    }
}

/// The row that names the sleep window, or says it is off.
private struct SleepModeRowLabel: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        LabeledContent(
            "Sleep mode", value: environment.sleepMode.window.map { $0.label } ?? "Off")
    }
}

/// This iPhone's push: whether it can receive one, on or off, paused for a while, and the alarm
/// switch. Which kinds reach the person at all is the registry switches above.
///
/// Enabling is an explicit opt-in rather than a prompt at launch. iOS shows the system permission
/// alert at most once per install and never again, so asking at a moment the person did not
/// choose spends the only chance there is, over whatever screen they were actually looking at,
/// for a feature they have not asked about yet. Here, the tap is the consent.
struct ThisPhoneDeliverySection: View {
    let settings: SettingsStore
    @Environment(AppEnvironment.self) private var environment

    private var devices: PushDevicesStore { settings.pushDevices }

    var body: some View {
        // Device push registration is a person's own route, a guest's included.
        if environment.connection?.me.capabilities.canRegisterPush == true,
            let push = environment.connection?.push
        {
            Section {
                switch push.registration.status {
                case .notRequested:
                    Button("Enable push on this iPhone") {
                        Task {
                            await PushRegistrar.requestAuthorizationIfNeeded(store: push)
                            await push.registerWithBackendIfNeeded()
                            await devices.load()
                        }
                    }
                    .accessibilityIdentifier("enable-notifications")
                case .authorized:
                    authorized(push)
                case .denied:
                    LabeledContent("Push on this iPhone", value: "Off in iOS Settings")
                case .failed:
                    LabeledContent("Push on this iPhone", value: "Unavailable")
                }
                if let error = devices.errorMessage {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            } header: {
                Text("Push · \(SettingsScope.thisDevice.label)")
            } footer: {
                Text(footer(push))
            }
            .task { await environment.connection?.pushChannels.load() }
        }
    }

    @ViewBuilder
    private func authorized(_ push: PushRegistrationStore) -> some View {
        if let phone = devices.thisDevice {
            Toggle(
                "Push on this iPhone",
                isOn: Binding(
                    get: { phone.pushEnabled }, set: { on in Task { await devices.setEnabled(on, on: phone) } })
            )
            .accessibilityIdentifier("push-enabled")
            pauseRow(phone)
            // Through the registration, not the device row: the phone sends its mutes on every
            // registration, so a mute written only to the row would be put back at the next launch.
            if environment.connection?.pushChannels.offeredIds.contains("alarm") == true {
                Toggle(
                    "Ring alarms on this iPhone",
                    isOn: Binding(
                        get: { !push.registration.isMuted("alarm") },
                        set: { on in Task { await push.setMuted(!on, forChannel: "alarm") } })
                )
                .accessibilityIdentifier("push-channel-alarm")
            }
        } else if push.registration.registeredToken == nil {
            LabeledContent("Push on this iPhone", value: "Not yet registered")
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func pauseRow(_ phone: PushDevice) -> some View {
        if let until = phone.pausedUntilDate(after: Date()) {
            HStack {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Spacer()
                Button("Resume now") { Task { await devices.resume(phone) } }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("push-resume")
            }
        } else {
            Menu("Pause push…") {
                ForEach(PushPausePreset.presets(now: Date(), zone: .current)) { preset in
                    Button(preset.label) { Task { await devices.pause(phone, until: preset.until) } }
                }
            }
            .accessibilityIdentifier("push-pause")
        }
    }

    private func footer(_ push: PushRegistrationStore) -> String {
        switch push.registration.status {
        case .denied:
            "Turned off in iOS Settings. Only the Settings app can turn it back on."
        case .failed:
            "This device could not be registered with Apple. It will try again next launch."
        case .authorized:
            "While you are using PAI on any device, nothing is pushed: a short banner at the top of the app shows what arrives. Nothing is caught up after a pause."
        default:
            "Get a push on this device when something needs you."
        }
    }
}

/// The person's other iPhones and browsers: whether each is paused, and a way to pause or resume.
struct OtherDevicesSection: View {
    let store: PushDevicesStore

    var body: some View {
        if !store.otherDevices.isEmpty {
            Section {
                ForEach(store.otherDevices) { device in
                    row(device)
                }
            } header: {
                Text("Your other devices · \(SettingsScope.synced.label)")
            }
        }
    }

    private func row(_ device: PushDevice) -> some View {
        let paused = device.pausedUntilDate(after: Date())
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(detail(device, pausedUntil: paused))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            Spacer(minLength: 0)
            if paused != nil {
                Button("Resume now") { Task { await store.resume(device) } }
                    .buttonStyle(.borderless)
            } else {
                Menu("Pause") {
                    ForEach(PushPausePreset.presets(now: Date(), zone: .current)) { preset in
                        Button(preset.label) { Task { await store.pause(device, until: preset.until) } }
                    }
                }
            }
        }
        .accessibilityIdentifier("push-device-\(device.id)")
    }

    private func detail(_ device: PushDevice, pausedUntil: Date?) -> String {
        if let pausedUntil { return "Paused until \(pausedUntil.formatted(date: .omitted, time: .shortened))" }
        if !device.pushEnabled { return "Push off" }
        if let sleep = device.sleep { return "Sleep mode \(sleep.start)–\(sleep.end)" }
        return "Push on"
    }
}
