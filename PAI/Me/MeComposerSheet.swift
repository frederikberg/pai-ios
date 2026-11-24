import PAIKit
import SwiftUI
import UIKit

/// Where the composer writes: a new entry (the draft kept on the phone) or a change to a stored one.
enum MeComposerMode: Identifiable {
    case new
    case edit(SelfReport)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let report): "edit-\(report.id)"
        }
    }
}

/// The self-report composer. It never asks for anything: a face, a few words, or both. Send always
/// succeeds locally; the entry waits in the outbox when there is no network.
struct MeComposerSheet: View {
    let mode: MeComposerMode
    /// Seed for the face when the sheet opens from one of the faces on Today.
    var initialFeel: SelfReportFeel?

    @Environment(AppEnvironment.self) private var environment
    @Environment(SelfReportStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    /// Only an edit holds its own copy; a new entry reads and writes the stores directly, so the
    /// words dictation appends and the words typed here can never diverge.
    @State private var editing = SelfReportDraft()
    @State private var timePopover = false
    @State private var sending = false
    @FocusState private var focused: Bool

    private let presenter = MePresenter()

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// The draft being composed. For a new entry it is the stores' own; the editing copy otherwise.
    private var working: Binding<SelfReportDraft> {
        if isEditing { return $editing }
        return Binding(get: { store.draft }, set: { value in store.updateDraft { $0 = value } })
    }

    private var dictation: ComposerDictation? {
        guard !isEditing, let voice = environment.connection?.voice else { return nil }
        return ComposerDictation(controller: voice, draftKey: SelfReportStore.dictationKey)
    }

    /// Typing while a take is Finishing means the same as tapping the button then: stop waiting.
    /// The take's final words still come back, in place of its partial ones.
    private var textBinding: Binding<String> {
        Binding(
            get: { working.wrappedValue.text },
            set: { newValue in
                working.wrappedValue.text = newValue
                if let dictation, dictation.isRecordingHere, dictation.controller.state == .stopping {
                    dictation.controller.stopWaiting()
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            field
            if working.wrappedValue.isPrivate {
                Label {
                    Text("Private — agents see only the time and the face unless you say so")
                } icon: {
                    Image(systemName: "lock")
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(MeColor.lock(dark: scheme == .dark))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("me-composer-private-note")
            }
        }
        .background(PaiPalette.Semantic.panelBackground, ignoresSafeAreaEdges: .all)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomInset }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: seed)
        .task { focused = true }
        .accessibilityIdentifier("me-composer")
    }

    /// The words. While a live take writes them the editor gives way to a read-only view held at
    /// the bottom, because a text editor does not follow text appended from outside; the editor
    /// returns when the take stops.
    @ViewBuilder
    private var field: some View {
        if dictation?.ownsBox == true {
            ScrollView {
                Text(working.wrappedValue.text)
                    .font(.system(size: 17))
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .accessibilityIdentifier("me-composer-live-text")
        } else {
            TextEditor(text: textBinding)
                .font(.system(size: 17))
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("me-composer-text")
        }
    }

    private func seed() {
        switch mode {
        case .new:
            if let initialFeel, store.draft.feel == nil { store.updateDraft { $0.feel = initialFeel.wire } }
        case .edit(let report):
            editing = SelfReportDraft(
                text: report.text ?? "", feel: report.feel?.wire, isPrivate: report.isPrivate, at: report.date)
        }
    }

    private var header: some View {
        HStack {
            Button(isEditing ? "Cancel" : "Close") { dismiss() }
                .accessibilityIdentifier("me-composer-close")
            Spacer()
            Button {
                timePopover = true
            } label: {
                HStack(spacing: 4) {
                    Text(timeLabel)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(PaiPalette.Semantic.raisedSurface, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("me-composer-time")
            .popover(isPresented: $timePopover) { timePicker.presentationCompactAdaptation(.popover) }
            Spacer()
            // Balances the Close button so the time chip sits in the middle.
            Text(isEditing ? "Cancel" : "Close").hidden()
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var timeLabel: String {
        guard let at = working.wrappedValue.at else { return "Now · \(presenter.shortDay(date: Date()))" }
        return "\(presenter.shortDay(date: at)) \(presenter.clock(at))"
    }

    private var timePicker: some View {
        VStack(spacing: 8) {
            DatePicker(
                "When",
                selection: Binding(
                    get: { working.wrappedValue.at ?? Date() }, set: { working.wrappedValue.at = $0 }),
                in: ...Date(), displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .environment(\.locale, ClockTime.pickerLocale)
            .environment(\.timeZone, presenter.calendar.timeZone)
            Button("Now") {
                working.wrappedValue.at = nil
                timePopover = false
            }
        }
        .padding()
        .frame(minWidth: 320)
    }

    // MARK: Bottom inset

    /// The dictation status above the toolbar, in the order the session composer uses: the take's
    /// own line and level meter, else the batch line, else why a start failed.
    private var bottomInset: some View {
        VStack(spacing: 0) {
            if let dictation, let voice = environment.connection?.voice {
                VStack(alignment: .leading, spacing: 6) {
                    if dictation.isRecordingHere {
                        VoiceRecordingIndicator(controller: voice)
                        if voice.state.showsMicrophoneLevel { VoiceVolumeOverlay(controller: voice) }
                    } else if voice.isTranscribingBatch(draftKey: dictation.draftKey) {
                        BatchTranscribingLine()
                    } else if voice.hasStuckBatchTake(draftKey: dictation.draftKey) {
                        BatchTranscribingLine(isStuck: true)
                    }
                    if let failure = voice.setupFailure?.userMessage ?? voice.lastStartFailure?.userMessage {
                        Text(failure)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                            .accessibilityIdentifier("voice-failure-message")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, hasStatus(dictation, voice) ? 8 : 0)
            }
            toolbar
        }
        .background(PaiPalette.Semantic.panelBackground)
    }

    private func hasStatus(_ dictation: ComposerDictation, _ voice: VoiceRecorderController) -> Bool {
        dictation.ownsTake || voice.setupFailure != nil || voice.lastStartFailure != nil
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            ForEach(SelfReportFeel.allCases, id: \.wire) { feel in
                faceButton(feel)
            }
            Rectangle().fill(PaiPalette.Semantic.borderDefault).frame(width: 1, height: 28)
            privateToggle
            Spacer(minLength: 0)
            if let dictation, let voice = environment.connection?.voice {
                micButton(dictation, voice)
            }
            sendSlot
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(PaiPalette.Semantic.borderDefault).frame(height: 1) }
    }

    /// Tap starts the default mode, a long press the other one — the session composer's mic.
    private func micButton(_ dictation: ComposerDictation, _ voice: VoiceRecorderController) -> some View {
        VoiceRecorderButton(
            controller: voice,
            isMine: dictation.micIsMine,
            canStartOverride: dictation.canStartOverride,
            onStart: { mode in start(dictation, mode) },
            alternateMode: settings.alternateRecordingMode
        ) {
            start(dictation, settings.defaultRecordingMode)
        }
    }

    private func start(_ dictation: ComposerDictation, _ mode: VoiceSttMode) {
        Task { await dictation.toggle(sttMode: mode, preText: store.draft.text) }
    }

    /// Mute holds the slot while a take records; Finishing gives it back to Send, which stays off
    /// until the words have arrived.
    @ViewBuilder
    private var sendSlot: some View {
        if let dictation, let voice = environment.connection?.voice, dictation.isRecordingHere,
            voice.state != .stopping
        {
            MuteButton(controller: voice) { voice.toggleMute() }
                .frame(width: 44, height: 44)
        } else {
            sendButton
        }
    }

    private var canSubmit: Bool {
        working.wrappedValue.canSend && !sending && dictation?.wordsAreOnTheWay != true
    }

    private func faceButton(_ feel: SelfReportFeel) -> some View {
        let selected = working.wrappedValue.feel == feel.wire
        let color = MeColor.feel(feel, dark: scheme == .dark)
        return Button {
            working.wrappedValue.feel = selected ? nil : feel.wire
        } label: {
            FeelFace(feel: feel, size: 34)
                .padding(3)
                .overlay(Circle().stroke(color.opacity(selected ? 0.35 : 0), lineWidth: 3))
                .opacity(working.wrappedValue.feel == nil || selected ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(feel.spokenName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("me-composer-face-\(feel.wire ?? "other")")
    }

    /// A lock in a capsule, violet when on; the violet line above the field spells the state, so
    /// the toolbar keeps its room for the microphone.
    private var privateToggle: some View {
        let color = MeColor.lock(dark: scheme == .dark)
        let on = working.wrappedValue.isPrivate
        return Button {
            working.wrappedValue.isPrivate.toggle()
        } label: {
            Image(systemName: "lock")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? color : PaiPalette.Semantic.textMuted)
                .frame(width: 40, height: 36)
                .background(on ? color.opacity(0.14) : .clear, in: Capsule())
                .overlay(Capsule().stroke(on ? color.opacity(0.55) : PaiPalette.surface600, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Private")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("me-composer-private")
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(PaiPalette.primary500, in: Circle())
                .opacity(canSubmit ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .accessibilityLabel(isEditing ? "Save" : "Send")
        .accessibilityIdentifier("me-composer-send")
    }

    private func submit() {
        guard canSubmit else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch mode {
        case .new:
            let privately = store.draft.isPrivate
            guard store.send() else { return }
            toasts.show(privately ? "Saved privately" : "Saved", kind: .success)
            dismiss()
        case .edit(let report):
            sending = true
            Task {
                let work = editing
                let text = work.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let patch = SelfReportPatchBody(
                    text: text.isEmpty ? nil : text, clearText: text.isEmpty, feel: work.feel,
                    clearFeel: work.feel == nil, isPrivate: work.isPrivate,
                    at: work.at != report.date ? work.at.map(AlarmTime.wireString) : nil)
                let saved = await store.update(id: report.id, patch)
                sending = false
                if saved {
                    toasts.show("Saved", kind: .success)
                    dismiss()
                } else {
                    toasts.show(store.errorMessage ?? "Could not save", kind: .error)
                }
            }
        }
    }
}

extension MePresenter {
    /// "Tue 24 Nov" for a moment, on the zone's calendar.
    func shortDay(date: Date) -> String { shortDay(key: dayKey(date)) }
}
