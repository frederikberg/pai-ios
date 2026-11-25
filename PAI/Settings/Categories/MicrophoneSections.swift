import PAIKit
import SwiftUI

/// How this iPhone listens, and how what is dictated is transcribed. The microphone and the
/// silence gate are properties of this phone; the rest is the person's, the same on every device.
struct MicrophoneSections: View {
    let settings: SettingsStore
    @Environment(AppEnvironment.self) private var environment

    /// `nil` only in the moment between sign-out and a fresh sign-in, when this screen is not
    /// reachable anyway.
    private var voice: VoiceRecorderController? { environment.connection?.voice }

    var body: some View {
        ScopedSection(
            title: "Input", scope: .thisDevice,
            footer:
                "The silence gate stops sending audio after 5 s of quiet and resumes with the second before speech; Auto adapts to the room."
        ) {
            // `AVAudioSession` names every input port whether or not the mic has ever been
            // granted, unlike the web's `enumerateDevices()`, so this is a real picker rather than
            // a device id typed in blind.
            if let voice {
                Picker("Microphone", selection: micDeviceBinding) {
                    Text("System default").tag("")
                    ForEach(voice.availableMicrophones) { option in
                        Text(option.name).tag(option.uid)
                    }
                }
                .accessibilityIdentifier("mic-device")
            }
            Toggle("Silence gate", isOn: gateEnabledBinding)
                .accessibilityIdentifier("silence-gate-enabled")
            if settings.silenceGate.enabled {
                Picker("Threshold", selection: gateModeBinding) {
                    Text("Auto").tag(SilenceGateMode.auto)
                    Text("Manual").tag(SilenceGateMode.manual)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("silence-gate-mode")
                if settings.silenceGate.mode == .manual {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quiet below \(settings.silenceGate.manualThresholdDb) dBFS")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textSecondary)
                        Slider(
                            value: manualThresholdBinding,
                            in: Double(
                                SilenceGateSettings.manualRange.lowerBound)...Double(
                                    SilenceGateSettings.manualRange.upperBound),
                            step: 1
                        )
                        .accessibilityIdentifier("silence-gate-threshold")
                    }
                }
            }
        }

        RegistryPlaceholder(store: settings.registry)
        ScopedSection(
            title: "Dictation", scope: .synced,
            footer:
                "Applies to every dictation: the composer, a call, the laptop, and re-transcribing a recording. Pressing the microphone starts the default recording; a long press or the composer's plus menu starts the other."
        ) {
            RegistryRows(
                store: settings.registry,
                keys: [
                    "recording_mode", "stt_language", "stt_no_verbatim", "stt_batch_pause_s", "stt_keyterms",
                ])
        }
    }

    private var gateEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.silenceGate.enabled },
            set: { enabled in
                var gate = settings.silenceGate
                gate.enabled = enabled
                settings.setSilenceGate(gate)
            })
    }

    private var gateModeBinding: Binding<SilenceGateMode> {
        Binding(
            get: { settings.silenceGate.mode },
            set: { mode in
                var gate = settings.silenceGate
                gate.mode = mode
                settings.setSilenceGate(gate)
            })
    }

    private var manualThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settings.silenceGate.manualThresholdDb) },
            set: { value in
                var gate = settings.silenceGate
                gate.manualThresholdDb = Int(value.rounded())
                settings.setSilenceGate(gate)
            })
    }

    private var micDeviceBinding: Binding<String> {
        Binding(get: { settings.micDeviceId }, set: { settings.setMicDeviceId($0) })
    }
}
