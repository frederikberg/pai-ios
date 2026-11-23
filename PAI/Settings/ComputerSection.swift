import PAIKit
import SwiftUI

/// What Computer acts through.
///
/// Every value here is one backend setting read by every client — the phone, the browser and
/// the watch all get whatever is set here, because the backend is the only thing that speaks.
/// There is deliberately no per-client override.
struct ComputerSection: View {
    let settings: SettingsStore

    var body: some View {
        Section {
            SecretField(
                title: "Home Assistant token", identifier: "home-assistant-token",
                field: settings.homeAssistantToken)
            SecretField(
                title: "Todoist token", identifier: "todoist-token", field: settings.todoistToken)
        } header: {
            Text("Computer's Keys")
        } footer: {
            Text(
                "Lights, automations and tasks only work once these are set. Held encrypted on the server; never shown again."
            )
        }

        SpokenVoiceSection(store: settings.voices)
    }
}

/// The synced voice settings, in three groups: Computer's model and turn taking, call mode
/// (ElevenLabs text-to-speech reading a session's replies during a call) and dictation
/// (ElevenLabs Scribe). One Save for all of them: they are one row on the backend.
struct SpokenVoiceSection: View {
    let store: SpokenVoiceSettingsStore

    private static let elevenLabsVoicesURL = URL(string: "https://elevenlabs.io/app/voice-library")!

    var body: some View {
        if store.draft != nil {
            if let choices = store.loaded?.computerChoices {
                computerGroup(choices)
            }
            callGroup
            dictationGroup
            Section {
                Button("Save") { Task { await store.save() } }
                    .disabled(!store.canSave)
                    .accessibilityIdentifier("save-voices")
                if let error = store.saveError {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
        } else {
            Section {
                if let error = store.loadError {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Voices")
            }
            .task { if store.loaded == nil { await store.load() } }
        }
    }

    /// Every option and default comes from the backend's `computer_choices`; an empty selection
    /// is "the default" and goes out as `null`.
    private func computerGroup(_ choices: ComputerChoices) -> some View {
        let defaults = choices.defaults
        return Section {
            Picker("Claude model", selection: modelBinding(choices)) {
                Text("Default (\(defaults.computerClaudeModel))").tag("")
                ForEach(choices.modelIds, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("computer-claude-model")
            Picker("Claude effort", selection: field(\.computerClaudeEffort)) {
                Text("Default (\(defaults.computerClaudeEffort))").tag("")
                ForEach(choices.efforts(forModel: store.draft?.computerClaudeModel ?? ""), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .accessibilityIdentifier("computer-claude-effort")
            Picker("Turn taking", selection: field(\.computerTurnPreset)) {
                Text("Default (\(defaults.computerTurnPreset))").tag("")
                ForEach(choices.presetNames, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("computer-turn-preset")
            Text(choices.summary(ofPreset: store.draft?.computerTurnPreset ?? ""))
                .font(PaiTypography.caption.font)
            DisclosureGroup("Advanced") {
                TextField(
                    "Turn tunables as JSON, e.g. {\"end_wait_s\": 2}", text: field(\.computerTurnTunables),
                    axis: .vertical
                )
                .lineLimit(2...8)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("computer-turn-tunables")
                if !store.isTunablesValid {
                    invalid("The turn tunables must be a JSON object, or empty.")
                }
            }
        } header: {
            Text("Computer")
        } footer: {
            Text(
                "The model and effort apply from the next call, the turn taking from the next turn. A tunable name the server does not know is refused when you save."
            )
        }
    }

    /// Choosing a model puts back an effort the new model does not accept.
    private func modelBinding(_ choices: ComputerChoices) -> Binding<String> {
        Binding(
            get: { store.draft?.computerClaudeModel ?? "" },
            set: { store.draft?.chooseModel($0, choices: choices) }
        )
    }

    private var callGroup: some View {
        Section {
            TextField("Call voice — ElevenLabs voice id", text: field(\.callVoiceId))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("call-voice-id")
            Link("Voice library", destination: Self.elevenLabsVoicesURL)
            LabeledContent("Call speed") {
                TextField("1", text: field(\.callSpeed))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("call-speed")
            }
            if !store.isSpeedValid {
                invalid("Speed must be a number between \(bounds(callSpeedRange)).")
            }
        } header: {
            Text("Call voice")
        } footer: {
            Text(
                "Reads a session's replies to you during a call. Empty is the built-in voice. Replies read aloud outside a call use the playback voices below."
            )
        }
    }

    private var dictationGroup: some View {
        Section {
            TextField("Key terms, comma-separated", text: field(\.sttKeyterms), axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("stt-keyterms")
            if let problem = store.draft?.keytermProblem {
                invalid(problem)
            }
            TextField("Language code — empty detects it", text: field(\.sttLanguage))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("stt-language")
            Toggle("Drop filler words", isOn: noVerbatim)
                .accessibilityIdentifier("stt-no-verbatim")
            Toggle("Transcribe batch takes while recording", isOn: batchPauseEnabled)
                .accessibilityIdentifier("stt-batch-pause-enabled")
            if store.draft?.sttBatchPauseEnabled == true {
                LabeledContent("After a pause of (seconds)") {
                    TextField("\(sttBatchPauseDefault)", text: field(\.sttBatchPauseS))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("stt-batch-pause-seconds")
                }
                if !store.isBatchPauseValid {
                    invalid(
                        "Seconds must be a whole number between \(sttBatchPauseRange.lowerBound) and \(sttBatchPauseRange.upperBound)."
                    )
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text(
                "Applies to every dictation: the composer, a call, the laptop, and re-transcribing a recording. "
                    + "Key terms bias recognition toward names it would otherwise miss, and cost extra. "
                    + "Dropping filler words also drops false starts. "
                    + "A batch take is transcribed in the background after each pause of the set length, "
                    + "so a long take does not wait until the end."
            )
        }
    }

    private func invalid(_ text: String) -> some View {
        Text(text)
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.errorText)
    }

    private func bounds(_ range: ClosedRange<Double>) -> String {
        "\(range.lowerBound) and \(range.upperBound)"
    }

    private var noVerbatim: Binding<Bool> {
        Binding(
            get: { store.draft?.sttNoVerbatim ?? false },
            set: { store.draft?.sttNoVerbatim = $0 }
        )
    }

    private var batchPauseEnabled: Binding<Bool> {
        Binding(
            get: { store.draft?.sttBatchPauseEnabled ?? false },
            set: { store.draft?.sttBatchPauseEnabled = $0 }
        )
    }

    /// One binding builder for every text field — a `Binding` per field written out would be as
    /// many places to get the same `draft == nil` guard right.
    private func field(_ key: WritableKeyPath<SpokenVoiceSettingsDraft, String>) -> Binding<String> {
        Binding(
            get: { store.draft?[keyPath: key] ?? "" },
            set: { store.draft?[keyPath: key] = $0 }
        )
    }
}
