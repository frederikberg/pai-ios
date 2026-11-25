import PAIKit
import SwiftUI

/// How replies, calls and Computer sound to the person. One place to try a voice and put it to a
/// use; below it one card per use, each with its own voice and speed. Calls and Computer are the
/// owner's, so a guest's page holds the first two cards only. Every value is a registry key.
struct VoicesSections: View {
    let settings: SettingsStore
    private var registry: SettingsRegistryStore { settings.registry }

    var body: some View {
        RegistryPlaceholder(store: registry)
        TryVoiceSection(settings: settings)

        ScopedSection(
            title: "Read aloud", scope: .synced,
            footer:
                "Your voice reads replies aloud for you, on every device; the default is the voice the owner set for everyone. Your speed is also set by the speed buttons in the player."
        ) {
            VoiceKeyRow(
                registry: registry, voices: settings.playbackVoices, key: "playback_voice_id",
                title: "Voice", emptyLabel: { "Default (\($0.defaultVoiceLabel))" })
            if registry.field("playback_speed") != nil {
                Picker(
                    "Speed",
                    selection: Binding(
                        get: { registry.playbackSpeed ?? 1 },
                        set: { speed in Task { await registry.updatePerson(["playback_speed": .double(speed)]) } })
                ) {
                    ForEach(PlaybackModel.speeds, id: \.self) { speed in
                        Text("\(speed.formatted())×").tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("playback-speed")
            }
        }
        .id(FixtureScrollAnchor.playbackVoice.rawValue)
        .fixtureFact("playbackVoice", readAloudFact)

        if registry.field("call_voice_id") != nil {
            ScopedSection(
                title: "Calls", scope: .synced,
                footer:
                    "Reads a session's replies to you during a call. Replies read aloud outside a call use the voice above."
            ) {
                VoiceKeyRow(
                    registry: registry, voices: settings.playbackVoices, key: "call_voice_id", title: "Voice",
                    emptyLabel: { "Default (\($0.defaultVoiceLabel))" })
                RegistryRows(store: registry, keys: ["call_speed", "call_stt_keyterms"])
            }
        }

        if registry.field("computer_voice_id") != nil {
            ScopedSection(
                title: "Computer", scope: .synced,
                footer:
                    "The turn taking applies from Computer's next turn. A tunable name the server does not know is refused when you save."
            ) {
                VoiceKeyRow(
                    registry: registry, voices: settings.playbackVoices, key: "computer_voice_id", title: "Voice",
                    emptyLabel: { _ in "Same as calls" })
                RegistryRows(store: registry, keys: ["computer_speed", "computer_turn_preset"])
                DisclosureGroup("Advanced") {
                    RegistryRows(store: registry, keys: ["computer_turn_tunables"])
                }
            }
        }
    }

    private var readAloudFact: String {
        guard let list = settings.playbackVoices.voices else { return "" }
        switch PlaybackVoiceSelection.of(registry.playbackVoiceId, listed: list.elevenlabs) {
        case .defaultVoice: return "Default (\(list.defaultVoiceLabel))"
        case let .listed(id): return list.elevenlabs.first { $0.voiceId == id }?.label ?? id
        case .custom: return "custom"
        }
    }
}

/// One place to hear a voice and put it to a use: pick it, play ElevenLabs' free preview, and send
/// it to Read aloud, Calls or Computer in one tap. A guest is offered only Read aloud.
struct TryVoiceSection: View {
    let settings: SettingsStore
    @Environment(ToastCenter.self) private var toasts
    /// The voice id tried; empty is the default voice.
    @State private var tried = ""

    private var registry: SettingsRegistryStore { settings.registry }
    private var voices: PlaybackVoicesStore { settings.playbackVoices }

    var body: some View {
        if let list = voices.voices {
            ScopedSection(
                title: "Try a voice", scope: .synced,
                footer: "A sample is ElevenLabs' own free preview, so trying costs nothing."
            ) {
                Picker("Voice", selection: $tried) {
                    Text("Default (\(list.defaultVoiceLabel))").tag("")
                    ForEach(list.elevenlabs) { voice in
                        Text(voice.label).tag(voice.voiceId)
                    }
                }
                .accessibilityIdentifier("try-voice-picker")
                Button(tryTitle) {
                    // A reply in hand would talk over the sample.
                    PlaybackController.shared.pause()
                    Task { await voices.tryVoice(tried.isEmpty ? nil : tried) }
                }
                .disabled(voices.sampleState == .loading)
                .accessibilityIdentifier("playback-voice-try")
                if let error = voices.sampleError {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use this voice for")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    HStack {
                        useButton("Read aloud", key: "playback_voice_id")
                        if registry.field("call_voice_id") != nil { useButton("Calls", key: "call_voice_id") }
                        if registry.field("computer_voice_id") != nil {
                            useButton("Computer", key: "computer_voice_id")
                        }
                    }
                }
            }
            .onDisappear { voices.stopSample() }
        }
    }

    private var tryTitle: String {
        switch voices.sampleState {
        case .idle: "Play sample"
        case .loading: "Loading…"
        case .playing: "Stop"
        }
    }

    private func useButton(_ title: String, key: String) -> some View {
        Button(title) {
            Task {
                let saved = await registry.update(key, to: tried.isEmpty ? .null : .string(tried))
                if let message = registry.errorMessage, !saved {
                    toasts.show(message, kind: .error)
                }
            }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("use-voice-\(key)")
    }
}

/// A voice id key as a picker over the account's voices: the empty choice (labelled by the
/// caller, since what "empty" means differs per use), a listed voice, or a typed id.
struct VoiceKeyRow: View {
    let registry: SettingsRegistryStore
    let voices: PlaybackVoicesStore
    let key: String
    let title: String
    let emptyLabel: (PlaybackVoices) -> String

    @Environment(ToastCenter.self) private var toasts
    /// "Another voice id…" picked: the typed id is shown even before it is saved.
    @State private var customPicked = false
    @State private var typed = ""

    private static let voiceLibraryURL = URL(string: "https://elevenlabs.io/app/voice-library")!

    /// The key as it stands, in whichever scope the schema puts it.
    private var stored: String? { registry.field(key)?.value.stringValue }

    var body: some View {
        if registry.field(key) != nil, let list = voices.voices {
            Picker(title, selection: selectionBinding(list)) {
                Text(emptyLabel(list)).tag(PlaybackVoiceSelection.defaultVoice)
                ForEach(list.elevenlabs) { voice in
                    Text(voice.label).tag(PlaybackVoiceSelection.listed(voice.voiceId))
                }
                Text("Another voice id…").tag(PlaybackVoiceSelection.custom)
            }
            .accessibilityIdentifier(key)
            if shown(list) == .custom {
                TextField("ElevenLabs voice id", text: $typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { commitTyped() }
                    .accessibilityIdentifier("\(key)-custom")
                Link("ElevenLabs voice library", destination: Self.voiceLibraryURL)
            }
        }
    }

    private func shown(_ list: PlaybackVoices) -> PlaybackVoiceSelection {
        customPicked ? .custom : .of(stored, listed: list.elevenlabs)
    }

    private func selectionBinding(_ list: PlaybackVoices) -> Binding<PlaybackVoiceSelection> {
        Binding(
            get: { shown(list) },
            set: { picked in
                switch picked {
                case .defaultVoice:
                    customPicked = false
                    save(.null)
                case let .listed(id):
                    customPicked = false
                    save(.string(id))
                case .custom:
                    customPicked = true
                    typed = stored ?? ""
                }
            })
    }

    /// A typed id is taken once the field is submitted; empty means the empty choice.
    private func commitTyped() {
        let next = typed.trimmingCharacters(in: .whitespaces)
        guard next != (stored ?? "") else { return }
        save(next.isEmpty ? .null : .string(String(next.prefix(64))))
    }

    private func save(_ value: SettingValue) {
        Task {
            let saved = await registry.update(key, to: value)
            if let message = registry.errorMessage, !saved { toasts.show(message, kind: .error) }
        }
    }
}
