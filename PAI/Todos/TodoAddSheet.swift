import PAIKit
import SwiftUI

/// How the add sheet takes words: one line read by the parser, or plain words, typed or
/// dictated, read by a model into one or several todos.
enum TodoAddMode: Equatable {
    case line, describe
}

/// One line for a new todo, keyboard up: what the New todo control, the Home Screen quick actions
/// and a page's plus open. What the server's parser reads in the line shows as chips while
/// typing, beside the open view's defaults, which a tap leaves off this todo; Add queues the todo
/// whether or not the parser has answered, and the sheet closes at once.
///
/// The sparkle switches to describing: the words go to the model when sent, and every todo it
/// read is queued as one change. The words stay in the sheet while it reads and when it fails.
struct TodoAddSheet: View {
    let todos: TodosStore
    @State var draft: TodoCaptureDraft
    /// The page it is added on: its view's defaults and its list apply, and the new row shows there.
    var place: TodoCreatePlace = .anywhere
    /// A line already typed when the sheet opens.
    var initialText: String?
    var initialMode: TodoAddMode = .line
    /// Told the id of the queued change, so whoever presented the sheet can say how it went.
    let onAdded: (String) -> Void
    /// Told what plain words became, so whoever presented the sheet can open the first todo.
    var onComposed: (TodosComposed) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var mode: TodoAddMode = .line
    @State private var dismissed: Set<String> = []
    @State private var reading = false
    @State private var failure: TodosComposeFailure?

    /// The plain words' own draft: dictation writes into it like into a session's composer, and
    /// it stays on this device.
    static let describeKey = DraftKey.local("todos-compose")

    private var drafts: DraftStore? { environment.connection?.drafts }

    private var dictation: ComposerDictation? {
        guard let voice = environment.connection?.voice else { return nil }
        return ComposerDictation(controller: voice, draftKey: Self.describeKey)
    }

    /// The words of the mode shown: the line's own, or the plain words' draft.
    private var words: Binding<String> {
        guard mode == .describe, let drafts else { return $draft.text }
        return Binding(
            get: { drafts.draft(for: Self.describeKey).text },
            set: { drafts.setDraftText(key: Self.describeKey, text: $0) })
    }

    private var today: String { todos.personsToday }

    /// The view's defaults still on this todo, then what the line read; "no date" in the line takes
    /// the view's day off as a tap would.
    private var chips: [TodoAddChip] {
        guard mode == .line else { return [] }
        let answer = draft.answer(for: draft.text)
        let gone = TodoCreate.cleared(dismissed, answer: answer)
        let defaults = TodoAddChip.defaults(place.defaults, dismissed: gone) { id in
            todos.lists.first { $0.id == id }?.name
        }
        return defaults + TodoAddChip.read(answer, today: today)
    }

    private var canSend: Bool {
        !words.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !reading
            && dictation?.wordsAreOnTheWay != true
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                field
                if mode == .line { chipRow } else { describeStatus }
                ForEach(mode == .line ? draft.issues : [], id: \.self) { issue in
                    Text(issue).font(.footnote).foregroundStyle(.secondary)
                }
                modeSwitch
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(mode == .line ? "New todo" : "Describe it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .line ? "Add" : "Send", action: send).disabled(!canSend)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: draft.text) {
            try? await Task.sleep(for: .seconds(TodoCaptureDraft.debounceSeconds))
            guard !Task.isCancelled else { return }
            await draft.read()
        }
        .task {
            mode = initialMode
            if let initialText, words.wrappedValue.isEmpty { words.wrappedValue = initialText }
            // A sheet opened with its words already there shows them and their chips whole;
            // otherwise the keyboard comes up for typing.
            focused = initialText == nil
        }
        .onChange(of: dictation?.wordsAreOnTheWay ?? false) { wasComing, coming in
            // A take that ends in this field is sent at once, as on the web.
            if wasComing, !coming, mode == .describe, canSend { send() }
        }
        .fixtureFact("todosAddMode", mode == .line ? "line" : "describe")
        .fixtureFact("todosAddChips", String(chips.count))
        .fixtureFact("todosAddDefaults", String(chips.filter { $0.dismissKey != nil }.count))
        .fixtureFact("todosAddWords", String(words.wrappedValue.split(separator: " ").count))
    }

    @ViewBuilder private var field: some View {
        if mode == .describe, dictation?.ownsBox == true {
            // A live take rewrites the words continuously; the field has no caret to offer then.
            ScrollView {
                Text(words.wrappedValue).font(.title3).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .defaultScrollAnchor(.bottom)
        } else {
            TextField(
                mode == .line ? "New todo" : "Say or write what needs doing", text: words, axis: .vertical
            )
            .font(.title3)
            .lineLimit(mode == .line ? 1...4 : 3...8)
            .focused($focused)
            .submitLabel(mode == .line ? .done : .return)
            .onSubmit { if mode == .line { send() } }
            .disabled(reading)
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    TodoAddChipView(chip: chip, tagColor: tagColor) {
                        if let key = chip.dismissKey { dismissed.insert(key) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var describeStatus: some View {
        HStack(spacing: 10) {
            if let dictation, let voice = environment.connection?.voice, let settings = environment.connection?.settings
            {
                VoiceRecorderButton(
                    controller: voice, isMine: dictation.micIsMine, canStartOverride: dictation.canStartOverride,
                    onStart: { sttMode in startDictation(dictation, sttMode) },
                    alternateMode: settings.alternateRecordingMode
                ) {
                    startDictation(dictation, settings.defaultRecordingMode)
                }
            }
            if reading {
                Text("Reading…").font(.footnote).foregroundStyle(.secondary)
            } else if dictation?.isRecordingHere == true, let voice = environment.connection?.voice {
                VoiceRecordingIndicator(controller: voice)
            }
            Spacer(minLength: 0)
        }
        if let failure {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    failure == .unread
                        ? "The model did not answer. Your words are kept."
                        : "There is no connection to read the words. They are kept."
                )
                .font(.footnote)
                .foregroundStyle(PaiPalette.Semantic.errorText)
                HStack(spacing: 16) {
                    Button("Try again", action: send)
                    Button("Add as typed", action: addAsTyped)
                }
                .font(.footnote.weight(.semibold))
            }
        }
    }

    private var modeSwitch: some View {
        Button {
            switchMode()
        } label: {
            Label(
                mode == .line ? "Describe it instead" : "Type one line instead",
                systemImage: mode == .line ? "sparkles" : "text.cursor"
            )
            .font(.footnote.weight(.semibold))
        }
        .disabled(reading)
        .accessibilityIdentifier("todo-add-mode")
    }

    private func tagColor(_ name: String) -> TodoColor {
        TodoIdentity.tagColor(name, chosen: TodoIdentity.chosenTagColors(todos.me?.tags ?? []))
    }

    /// Switching keeps the words.
    private func switchMode() {
        let carried = words.wrappedValue
        mode = mode == .line ? .describe : .line
        failure = nil
        words.wrappedValue = carried
    }

    private func startDictation(_ dictation: ComposerDictation, _ sttMode: VoiceSttMode) {
        Task { await dictation.toggle(sttMode: sttMode, preText: words.wrappedValue) }
    }

    private func send() {
        switch mode {
        case .line:
            guard let taken = draft.take() else { return }
            onAdded(todos.capture(text: taken.text, place: place, dismissed: dismissed, parsed: taken.answer))
            dismiss()
        case .describe:
            guard canSend else { return }
            let text = words.wrappedValue
            reading = true
            failure = nil
            // Unstructured, so the todos still arrive when the sheet is closed while the model reads.
            Task {
                do {
                    let composed = try await todos.compose(text: text, place: place)
                    drafts?.clearDraft(key: Self.describeKey)
                    reading = false
                    onComposed(composed)
                    dismiss()
                } catch {
                    reading = false
                    failure = error as? TodosComposeFailure ?? .unreachable
                }
            }
        }
    }

    /// The plain words as one todo, read by the parser like any line, so they are never lost.
    private func addAsTyped() {
        let text = words.wrappedValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onAdded(todos.capture(text: text, place: place, dismissed: dismissed))
        drafts?.clearDraft(key: Self.describeKey)
        dismiss()
    }
}

/// One chip under the add sheet's line. A default of the open view carries an ✕: a tap leaves it
/// off this todo. A nested tag shows its last part.
struct TodoAddChipView: View {
    let chip: TodoAddChip
    let tagColor: (String) -> TodoColor
    let onDismiss: () -> Void

    private var label: String { chip.kind == "tag" ? TodoIdentity.tagLeaf(chip.label) : chip.label }

    private var color: TodoColor? { chip.color ?? (chip.kind == "tag" ? tagColor(chip.label) : nil) }

    var body: some View {
        if chip.dismissKey != nil {
            Button(action: onDismiss) { face }
                .buttonStyle(.plain)
                .accessibilityLabel("\(chip.label), from the view; tap to leave it off")
        } else {
            face.accessibilityLabel(chip.label)
        }
    }

    private var face: some View {
        HStack(spacing: 4) {
            if chip.kind == "horizon", let color {
                Circle().strokeBorder(color.swatch, lineWidth: 1.5).frame(width: 10, height: 10)
            }
            Text(label).lineLimit(1)
            if chip.dismissKey != nil { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
        }
        .font(.footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(color?.chipText ?? PaiPalette.Semantic.textPrimary)
        .background(Capsule().fill(color?.chip ?? Color.secondary.opacity(0.15)))
    }
}
