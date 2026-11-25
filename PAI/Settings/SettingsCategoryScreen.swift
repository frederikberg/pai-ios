import PAIKit
import SwiftUI

/// One page of Settings. Which sections it holds is decided here by category; what each section
/// shows is its own. The registry is read again on every open, so a value changed on another
/// device is not shown stale.
struct SettingsCategoryScreen: View {
    let category: SettingsCategory

    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @State private var watchKeys = WatchKeysPresenter()
    @State private var ownSignIns: SignInsStore?
    @State private var everyoneSignIns: SignInsStore?

    var body: some View {
        Form {
            Section {
                Text(category.summary)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            .listRowBackground(Color.clear)
            content
        }
        .fixtureScrollsToAnchor()
        .watchKeyPresentations(watchKeys)
        .paiListBackground()
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await settings.registry.load()
            if category == .voices || category == .voiceSound { await settings.playbackVoices.load() }
            if category == .voices { await settings.computerModel.load() }
            if category == .models { await settings.computerModel.load() }
            await loadSignIns()
        }
        .accessibilityIdentifier("settings-category-\(category.rawValue)")
        .fixtureFact("settingsCategory", category.rawValue)
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .microphone: MicrophoneSections(settings: settings)
        case .notifications: NotificationsSections(settings: settings)
        case .voices: VoicesSections(settings: settings)
        case .appearance: AppearanceSections(settings: settings)
        case .location: LocationSection()
        case .devices:
            if let ownSignIns { DevicesSections(presenter: watchKeys, signIns: ownSignIns) } else { loading }
        case .history: HistorySections(settings: settings)
        case .thisPhone: ThisPhoneSections(settings: settings)
        case .system: SystemSections(settings: settings)
        case .alerts: AlertsAndRoutingSections(settings: settings)
        case .mail: MailServerSections(settings: settings)
        case .providers: ProvidersSections(settings: settings)
        case .models: ModelsSections(settings: settings)
        case .integrations: IntegrationsSections(settings: settings)
        case .voiceSound: VoiceSoundSections(settings: settings)
        case .agents: AgentsSections(settings: settings)
        case .people:
            if let everyoneSignIns { PeopleSections(store: everyoneSignIns) } else { loading }
        case .diagnostics: DiagnosticsSections()
        }
    }

    private var loading: some View {
        Section { ProgressView() }
    }

    /// The two sign-in lists are built where a client exists, and read once the page has opened.
    private func loadSignIns() async {
        guard let client = environment.connection?.apiClient else { return }
        if category == .devices, ownSignIns == nil {
            let store = SignInsStore(scope: .own, api: client)
            ownSignIns = store
            await store.load()
        }
        if category == .people, everyoneSignIns == nil {
            let store = SignInsStore(scope: .everyone, api: client)
            everyoneSignIns = store
            await store.load()
            await store.loadWatchKeys()
        }
    }
}
