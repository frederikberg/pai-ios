import PAIKit
import SwiftUI

// The Administration pages: what changes the instance, costs money, or concerns other people. The
// owner has them; a guest's Settings does not list them and none of their requests is made.

/// The machine PAI runs on, and what needs attention. The VM shell is a web-only tool.
struct SystemSections: View {
    let settings: SettingsStore
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let claude = environment.connection?.claudeAuth {
            ScopedSection(title: "Machine", scope: .everyone) {
                LabeledContent("Claude sign-in") {
                    Text(Self.claudeText(claude.auth))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                .accessibilityIdentifier("system-claude")
            }
            .task { await claude.refresh() }
        }
        AlertsSection(alerts: settings.alerts)
    }

    private static func claudeText(_ auth: ClaudeAuth) -> String {
        if !auth.known { return "Not reported yet." }
        if ClaudeAuthPredicates.isRejected(auth) {
            return "Anthropic is refusing the credential: sessions cannot start."
        }
        if ClaudeAuthPredicates.needsSignIn(auth) { return "Signed out: sessions cannot start." }
        return auth.subscription.map { "Signed in (\($0))." } ?? "Signed in."
    }
}

struct AlertsAndRoutingSections: View {
    let settings: SettingsStore

    var body: some View {
        AlertRoutingSections(routing: settings.alertRouting)
    }
}

struct MailServerSections: View {
    let settings: SettingsStore

    var body: some View {
        SmtpSection(smtp: settings.smtp)
    }
}

/// The services PAI calls and the keys it calls them with. Keys are held encrypted on the server and
/// never shown again.
struct ProvidersSections: View {
    let settings: SettingsStore

    var body: some View {
        ScopedSection(
            title: "ElevenLabs", scope: .everyone,
            footer:
                "Speech to text, calls, Computer and read-aloud. Required for voice transcription. Held encrypted on the server; never shown again once set."
        ) {
            SecretField(title: "API key", identifier: "elevenlabs-key", field: settings.elevenLabsKey)
        }
    }
}

/// Which model answers what. The defaults of the session types and Computer's own model; a table
/// of a default and a fallback per feature joins them when the server serves one.
struct ModelsSections: View {
    let settings: SettingsStore

    var body: some View {
        SessionDefaultsSection(store: settings.sessionDefaults)
        ComputerModelSection(store: settings.computerModel)
    }
}

/// Computer's Claude model and effort: saved on each pick, `Default` is the backend's own.
struct ComputerModelSection: View {
    let store: ComputerModelStore

    var body: some View {
        if let choices = store.choices {
            let defaults = choices.defaults
            ScopedSection(
                title: "Computer", scope: .everyone,
                footer: "The model and effort apply from Computer's next call."
            ) {
                Picker(
                    "Claude model",
                    selection: Binding(
                        get: { store.model }, set: { model in Task { await store.choose(model: model) } })
                ) {
                    Text("Default (\(defaults.computerClaudeModel))").tag("")
                    ForEach(choices.modelIds, id: \.self) { Text($0).tag($0) }
                }
                .disabled(store.isSaving)
                .accessibilityIdentifier("computer-claude-model")
                Picker(
                    "Claude effort",
                    selection: Binding(
                        get: { store.effort }, set: { effort in Task { await store.choose(effort: effort) } })
                ) {
                    Text("Default (\(defaults.computerClaudeEffort))").tag("")
                    ForEach(choices.efforts(forModel: store.model), id: \.self) { Text($0).tag($0) }
                }
                .disabled(store.isSaving)
                .accessibilityIdentifier("computer-claude-effort")
                if let error = store.saveError {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
        } else if let error = store.loadError {
            Section {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
    }
}

/// Services PAI reaches on its own, with a key the server holds so an agent can use them
/// unattended; MailVerdict is signed in by each device instead.
struct IntegrationsSections: View {
    let settings: SettingsStore

    var body: some View {
        ScopedSection(
            title: "Todoist", scope: .everyone,
            footer:
                "What Computer adds tasks with and the Me page reads today's list with. Held encrypted on the server; never shown again."
        ) {
            SecretField(title: "Todoist token", identifier: "todoist-token", field: settings.todoistToken)
        }
        ScopedSection(
            title: "Home Assistant", scope: .everyone,
            footer: "Computer's own non-admin Home Assistant user. Lights and automations only work once this is set."
        ) {
            SecretField(
                title: "Home Assistant token", identifier: "home-assistant-token", field: settings.homeAssistantToken)
        }
        ScopedSection(title: "Signed in by the device", scope: .everyone) {
            LabeledContent("MailVerdict") {
                Text("Each device signs in with your own login. Agents cannot use it unattended.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// The voice everyone starts with, and what is kept for diagnosing.
struct VoiceSoundSections: View {
    let settings: SettingsStore

    var body: some View {
        RegistryPlaceholder(store: settings.registry)
        ScopedSection(title: "For everyone", scope: .everyone) {
            VoiceKeyRow(
                registry: settings.registry, voices: settings.playbackVoices, key: "default_voice_id",
                title: "Default voice", emptyLabel: { _ in "Built-in" })
            RegistryRows(store: settings.registry, keys: ["playback_model", "debug_recordings_enabled"])
        }
    }
}

struct AgentsSections: View {
    let settings: SettingsStore

    var body: some View {
        StatusMessageSection(store: settings.statusMessage)
    }
}

/// Every person's sign-ins grouped by person, everyone's watch keys, and the machines that reach
/// PAI. Binding a machine key to an agent is a web-only action.
struct PeopleSections: View {
    let store: SignInsStore

    var body: some View {
        SignInListSections(store: store, showsPerson: true)
        Section {
            if store.watchKeys.isEmpty {
                Text("No watch key yet.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            ForEach(store.watchKeys) { key in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(key.name) · \(key.displayName ?? "Unknown person")")
                        Text(
                            key.lastUsedAt.flatMap(IsoTimestamp.date(from:))
                                .map {
                                    "\(key.hint)… · last used \($0.formatted(date: .abbreviated, time: .shortened))"
                                }
                                ?? "\(key.hint)… · never used"
                        )
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    Spacer(minLength: 0)
                    Button("Revoke", role: .destructive) { Task { await store.revokeWatchKey(key) } }
                        .buttonStyle(.borderless)
                        .disabled(store.isBusy)
                }
            }
        } header: {
            Text("Watch keys · \(SettingsScope.everyone.label)")
        }
        Section {
            if store.machines.isEmpty {
                Text("No key has been used yet.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            ForEach(store.machines) { machine in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SignInLabel.title(machine))
                        Text(machine.active ? SignInLabel.detail(machine) : "Revoked")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    Spacer(minLength: 0)
                    if machine.active {
                        Button("Revoke", role: .destructive) { Task { await store.revoke(machine) } }
                            .buttonStyle(.borderless)
                            .disabled(store.isBusy)
                    } else {
                        Button("Restore") { Task { await store.restore(machine) } }
                            .buttonStyle(.borderless)
                            .disabled(store.isBusy)
                    }
                }
                .accessibilityIdentifier("access-key-\(machine.id)")
            }
        } header: {
            Text("Access keys · \(SettingsScope.everyone.label)")
        } footer: {
            Text("Each key appears the first time it is used. Binding one to an agent is done on the web.")
        }
    }
}

/// What the speech engines heard, for finding out why something was misheard.
struct DiagnosticsSections: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showingDebugRecordings = false
    @State private var showingWakeWordSamples = false

    var body: some View {
        if let connection = environment.connection {
            ScopedSection(
                title: "Recordings", scope: .everyone,
                footer:
                    "Debug recordings and wake-word samples live on the server, so every device sees the same ones."
            ) {
                Button("Debug Recordings") { showingDebugRecordings = true }
                    .accessibilityIdentifier("open-debug-recordings")
                    .sheet(isPresented: $showingDebugRecordings) {
                        DebugRecordingsSheet(
                            apiClient: connection.apiClient,
                            microphoneBusy: {
                                connection.voice.state != .idle
                                    || connection.computerCall.isLive || connection.wakeWordSamples.isRunning
                            })
                    }
                Button("Wake-word Samples") { showingWakeWordSamples = true }
                    .accessibilityIdentifier("open-wake-word-samples")
                    .sheet(isPresented: $showingWakeWordSamples) {
                        NavigationStack {
                            WakeWordSampleScreen(controller: connection.wakeWordSamples)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Done") { showingWakeWordSamples = false }
                                    }
                                }
                        }
                    }
            }
        }
    }
}
