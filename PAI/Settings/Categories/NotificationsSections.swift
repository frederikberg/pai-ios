import PAIKit
import SwiftUI

/// What reaches the person, and where. The inbox keeps everything whatever is chosen here.
///
/// Until the server serves the notification matrix and the device list, this page is what the
/// older routes can say: whether an agent's notification may also be mailed, this iPhone's push
/// and its channels, and the sleep window.
struct NotificationsSections: View {
    let settings: SettingsStore
    /// Opens the sleep-mode screen from a launch argument; always `false` in a Release build.
    @State private var fixtureSleepSettings = false

    var body: some View {
        RegistryPlaceholder(store: settings.registry)
        ScopedSection(
            title: "Mail from agents", scope: .synced,
            footer: "Everything is always kept in Notifications. Push and mail are only how it also reaches you."
        ) {
            RegistryRows(store: settings.registry, keys: ["mail_from_agents"])
        }
        PushOnThisPhoneSection()
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
            Text("Puts the sessions and every push away on this iPhone for a window each day, guarded by a PIN.")
        }
        .navigationDestination(isPresented: $fixtureSleepSettings) { SleepModeSettingsScreen() }
        .task {
            #if DEBUG
                if PaiFixtureLaunch.isEnabled(), PaiFixtureLaunch.opensSleepSettings() { fixtureSleepSettings = true }
            #endif
        }
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

/// This iPhone's notifications: whether it can receive a push, and which channels it takes.
///
/// A notification is always kept in the notifications screen. A push is the delivery of one to
/// this device, and a channel is what this device can switch off; the choice is stored on the
/// server per device. Both channels off means no push here, and nothing in the notifications
/// screen changes.
///
/// Enabling is an explicit opt-in rather than a prompt at launch. iOS shows the system permission
/// alert at most once per install and never again, so asking at a moment the person did not
/// choose spends the only chance there is, over whatever screen they were actually looking at,
/// for a feature they have not asked about yet. Here, the tap is the consent.
struct PushOnThisPhoneSection: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        // Device push registration is a person's own route, a guest's included.
        if environment.connection?.me.capabilities.canRegisterPush == true {
            Section {
                if let push = environment.connection?.push, let channels = environment.connection?.pushChannels {
                    switch push.registration.status {
                    case .notRequested:
                        Button("Enable push on this iPhone") {
                            Task {
                                await PushRegistrar.requestAuthorizationIfNeeded(store: push)
                                await push.registerWithBackendIfNeeded()
                            }
                        }
                        .accessibilityIdentifier("enable-notifications")
                    case .authorized:
                        LabeledContent(
                            "Push on this iPhone",
                            value: push.registration.deviceStatusText(offeredChannelIds: channels.offeredIds))
                        ForEach(channels.rows(muted: push.registration.mutedChannels)) { channel in
                            Toggle(isOn: channelBinding(push, channel.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(channel.label)
                                    Text(channel.description)
                                        .font(PaiTypography.caption.font)
                                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                                }
                            }
                            .accessibilityIdentifier("push-channel-\(channel.id)")
                        }
                    case .denied:
                        LabeledContent("Push on this iPhone", value: "Off")
                    case .failed:
                        LabeledContent("Push on this iPhone", value: "Unavailable")
                    }
                }
            } header: {
                Text("Push · \(SettingsScope.thisDevice.label)")
            } footer: {
                Text(footer)
            }
            .task { await environment.connection?.pushChannels.load() }
        }
    }

    /// The toggle reads "receive this", the store holds "muted" — the two are opposites, and this
    /// is the only place they meet. See ``PushRegistration/mutedChannels`` for why what is stored
    /// is the mute.
    private func channelBinding(_ push: PushRegistrationStore, _ channelId: String) -> Binding<Bool> {
        Binding(
            get: { !push.registration.isMuted(channelId) },
            set: { wanted in Task { await push.setMuted(!wanted, forChannel: channelId) } }
        )
    }

    private var footer: String {
        switch environment.connection?.push.registration.status {
        case .denied:
            "Turned off in iOS Settings. Only the Settings app can turn it back on."
        case .failed:
            "This device could not be registered with Apple. It will try again next launch."
        case .authorized:
            "These switches decide what this device also gets as a push. While you are using PAI on any device, nothing is pushed: a short banner at the top of the app shows what arrives."
        default:
            "Get a push on this device when something needs you."
        }
    }
}
