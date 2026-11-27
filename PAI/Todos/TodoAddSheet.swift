import PAIKit
import SwiftUI

/// How the add sheet takes words: one line read by the parser, or plain words, typed or
/// dictated, read by a model into one or several todos.
enum TodoAddMode: Equatable {
    case line, describe
}

/// The section of the desk a todo is added into: its divider (nil for the cards above the first
/// one) and the words the sheet's heading names it by.
struct TodoAddDeskSection: Equatable {
    let dividerId: String?
    let title: String
}

/// The sheet a todo is made in: a panel from the bottom that sits on the keyboard. The line is
/// read by the server's parser while typing; what it reads, the open view's defaults (dashed, a
/// tap leaves one off) and what the pickers chose show as chips in one place. A tap on a field's
/// icon puts its picker where the keyboard was, with the line kept as typed.
///
/// Return and the round arrow add the todo and leave the sheet open for the next one, with the
/// view's defaults back in place; a note above the sheet opens the one just made. What is typed
/// is kept on the device until it is sent or discarded, and closing with words typed asks first.
///
/// Opened on a todo (`parent`) it adds subtasks, with everything a todo's sheet can do. The
/// sparkle switches to describing: plain words go to a model when sent, and every todo it reads
/// is queued as one change.
struct TodoAddSheet: View {
    let todos: TodosStore
    @State var draft: TodoCaptureDraft
    /// The page it is added on: its view's defaults and its list apply, and the new row shows there.
    var place: TodoCreatePlace = .anywhere
    /// What the heading names the place by: the page's title.
    var placeName: String?
    /// The todo subtasks are added under.
    var parent: Todo?
    var deskSection: TodoAddDeskSection?
    /// A line already typed when the sheet opens.
    var initialText: String?
    var initialMode: TodoAddMode = .line
    /// Asked to open a todo just added, once this sheet has left.
    var onOpen: (String) -> Void = { _ in }
    /// Told what plain words became, so whoever presented the sheet can open the first todo.
    var onComposed: (TodosComposed) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var mode: TodoAddMode = .line
    @State private var titleFocused = false
    @State private var describeFocused = false
    @State private var dismissed: Set<String> = []
    @State private var details = ""
    @State private var picks = TodoAddDraft()
    @State private var files: [StagedAttachment] = []
    @State private var picker: TodoPicker?
    @State private var pickerStep: TodoPickerPanel.Step?
    @State private var notice: Notice?
    @State private var asking = false
    @State private var restored = false
    @State private var shown = false
    @State private var editingDetails = false
    @State private var pickingPhoto = false
    @State private var pickingFile = false
    @State private var reading = false
    @State private var failure: TodosComposeFailure?

    /// What the sheet says above itself about the todo just sent.
    private struct Notice: Identifiable, Equatable {
        enum Kind: Equatable {
            case added(todoId: String?, changeId: String)
            case info
            /// The server refused it: the words can be put back into the line.
            case refused(words: String)
        }

        let id = UUID()
        let text: String
        let kind: Kind
    }

    /// The plain words' own draft: dictation writes into it like into a session's composer, and
    /// it stays on this device.
    static let describeKey = DraftKey.local("todos-compose")

    private var drafts: DraftStore? { environment.connection?.drafts }

    private var kept: TodoEntryDrafts { environment.todoEntryDrafts }

    private var keptKey: String {
        parent.map { TodoEntryDrafts.subtaskKey(parent: $0.id) } ?? TodoEntryDrafts.pageKey
    }

    private var dictation: ComposerDictation? {
        guard let voice = environment.connection?.voice else { return nil }
        return ComposerDictation(controller: voice, draftKey: Self.describeKey)
    }

    /// The plain words: the describe mode's own draft.
    private var plainWords: Binding<String> {
        guard let drafts else { return .constant("") }
        return Binding(
            get: { drafts.draft(for: Self.describeKey).text },
            set: { drafts.setDraftText(key: Self.describeKey, text: $0) })
    }

    private var words: String { mode == .line ? draft.text : plainWords.wrappedValue }

    private var today: String { todos.personsToday }

    private var answer: TodosParseAnswer? { draft.answer(for: draft.text) }

    /// What the sheet holds, as it is kept on the device.
    private var entry: TodoEntryDraft {
        var entry = TodoEntryDraft()
        entry.text = draft.text
        entry.description = details
        entry.picks = picks
        entry.dismissed = dismissed.sorted()
        return entry
    }

    private func listName(_ id: String) -> String? { todos.lists.first { $0.id == id }?.name }

    /// The view's defaults still on this todo, what the line read and what the pickers chose.
    private var chips: [TodoAddChip] {
        guard mode == .line else { return [] }
        return TodoAddChip.all(
            place: place, dismissed: dismissed, answer: answer, draft: picks, today: today, listName: listName
        )
        .filter { $0.kind != "parent" }
    }

    /// The fields the todo will get if it is sent now.
    private var values: TodoEntryValues {
        TodoEntryValues(
            create: TodoCreate.preview(
                title: draft.text, answer: answer, place: place, dismissed: dismissed, picks: picks, today: today))
    }

    /// The words that will move to the description, dimmed while typing.
    private var overflow: [Range<Int>] { TodoTitles.overflow(of: draft.text, tokens: answer?.tokens ?? []) }

    private var canSend: Bool {
        !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !reading
            && dictation?.wordsAreOnTheWay != true
    }

    private var heading: String {
        if let parent { return "Subtask of · \(parent.title)" }
        if mode == .describe { return "Describe it" }
        if let deskSection { return "New todo · \(deskSection.title)" }
        return placeName.map { "New todo · \($0)" } ?? "New todo"
    }

    /// As tall as the keyboard was, so the block above does not move when a picker takes its place.
    private var pickerHeight: CGFloat { max(260, TodoKeyboard.shared.lastHeight - TodoKeyboard.homeIndicatorInset) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? 0.4 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: requestClose)
                .accessibilityLabel("Close")
            VStack(spacing: 8) {
                if let notice { noticeView(notice) }
                panel
            }
        }
        .presentationBackground(.clear)
        .confirmationDialog("Discard this todo?", isPresented: $asking, titleVisibility: .visible) {
            Button("Discard this todo", role: .destructive) { close(discarding: true) }
            Button("Keep typing", role: .cancel) { titleFocused = picker == nil }
        } message: {
            Text("What you typed here is not saved as a todo yet.")
        }
        .sheet(isPresented: $editingDetails) {
            TodoDraftDescriptionSheet(text: $details, subtitle: draft.text)
        }
        .sheet(isPresented: $pickingPhoto) { PhotoAttachmentPicker { files += $0 } }
        .sheet(isPresented: $pickingFile) { FileAttachmentPicker { files += $0 } }
        .task(id: draft.text) {
            try? await Task.sleep(for: .seconds(TodoCaptureDraft.debounceSeconds))
            guard !Task.isCancelled else { return }
            await draft.read()
        }
        .task { restore() }
        .task(id: notice?.id) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation { notice = nil }
        }
        .onChange(of: entry) { _, entry in if restored { kept.keep(entry, for: keptKey) } }
        .onChange(of: dictation?.wordsAreOnTheWay ?? false) { wasComing, coming in
            // A take that ends in this field is sent at once, as on the web.
            if wasComing, !coming, mode == .describe, canSend { send() }
        }
        .fixtureFact("todosAddMode", mode == .line ? "line" : "describe")
        .fixtureFact("todosAddChips", String(chips.count))
        .fixtureFact("todosAddHorizon", chips.first { $0.kind == "horizon" }?.label ?? "")
        .fixtureFact("todosAddDefaults", String(chips.filter { $0.dismissKey != nil }.count))
        .fixtureFact("todosAddWords", String(words.split(separator: " ").count))
        .fixtureFact("todosAddPicker", picker?.rawValue ?? "")
        .fixtureFact("todosAddDimmed", String(overflow.count))
    }

    /// What was kept from last time comes back, unless the sheet was opened with words of its own.
    private func restore() {
        let held = kept.draft(for: keptKey)
        if let initialText {
            draft.text = initialText
        } else if draft.text.isEmpty {
            draft.text = held.text
        }
        details = held.description
        picks = held.picks
        dismissed = Set(held.dismissed)
        restored = true
        mode = parent == nil ? initialMode : .line
        if mode == .describe, let initialText, plainWords.wrappedValue.isEmpty { plainWords.wrappedValue = initialText }
        withAnimation(.easeOut(duration: 0.25)) { shown = true }
        #if DEBUG
            if let name = PaiFixtureLaunch.requestedTodosPicker() {
                if name == "nudge" {
                    picker = .when
                    pickerStep = .nudge
                } else {
                    picker = TodoPicker(rawValue: name)
                }
            }
        #endif
        // A sheet opened with its words already there shows them and their chips whole;
        // otherwise the keyboard comes up for typing.
        if initialText == nil, picker == nil {
            titleFocused = mode == .line
            describeFocused = mode == .describe
        }
    }

    // MARK: - The panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                grip
                if mode == .line { lineBlock } else { describeBlock }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            if let picker {
                Divider()
                TodoPickerPanel(picker: picker, editing: editing, startsAt: pickerStep) {
                    withAnimation(.easeOut(duration: 0.2)) { self.picker = nil }
                    titleFocused = true
                }
                .id(picker)
                .frame(height: pickerHeight)
            }
        }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(PaiPalette.Semantic.panelBackground)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// The handle and the heading: pulling them down closes like the ✕.
    private var grip: some View {
        VStack(spacing: 6) {
            Capsule().fill(PaiPalette.Semantic.borderDefault).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
            HStack {
                Text(heading)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
                Spacer()
                Button(action: requestClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(PaiPalette.Semantic.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(PaiPalette.Semantic.raisedSurface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { drag in
                if drag.translation.height > 50 { requestClose() }
            })
    }

    @ViewBuilder private var lineBlock: some View {
        TodoTitleField(
            text: $draft.text, placeholder: parent == nil ? "What needs doing?" : "Subtask", dimmed: overflow,
            isFocused: titleFocused,
            onFocusChange: { focused in
                if titleFocused != focused { titleFocused = focused }
                if focused, picker != nil { withAnimation(.easeOut(duration: 0.2)) { picker = nil } }
            },
            onReturn: send,
            onPasteImages: { images in
                files += images.map {
                    AttachmentCompression.stage(data: $0.data, filename: $0.filename, mimeType: $0.mimeType)
                }
            })
        if !overflow.isEmpty {
            Label("The dimmed part goes to the top of the description", systemImage: "text.alignleft")
                .font(.caption)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        Button {
            editingDetails = true
        } label: {
            Label(detailsLine, systemImage: "text.alignleft")
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(details.isEmpty ? PaiPalette.Semantic.textFaint : PaiPalette.Semantic.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(details.isEmpty ? "Add a description" : "Description: \(detailsLine)")
        TodoHeldFiles(
            items: files.map { TodoHeldFiles.Item(id: $0.id.uuidString, name: $0.filename, image: $0.previewImage) }
        ) { id in
            files.removeAll { $0.id.uuidString == id }
        }
        TodoFieldChips(chips: chips, tagColor: tagColor, onTap: tapChip)
        ForEach(draft.issues, id: \.self) { issue in
            Text(issue).font(.footnote).foregroundStyle(PaiPalette.Semantic.textSecondary)
        }
        TodoFieldRail(
            editing: editing, open: picker, onPick: openPicker, onPhoto: { pickingPhoto = true },
            onFile: { pickingFile = true }
        ) {
            if parent == nil {
                TodoRailButton(systemImage: "sparkles", label: "Describe it in plain words instead", action: switchMode)
            }
            if TodoKeyboard.shared.isUp {
                TodoRailButton(
                    systemImage: "keyboard.chevron.compact.down", label: "Hide keyboard", action: lowerKeyboard)
            }
            TodoRailButton(
                systemImage: "arrow.up", label: parent == nil ? "Add todo" : "Add subtask", prominent: true,
                disabled: !canSend, action: send)
        }
    }

    private var detailsLine: String {
        let line = details.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "Description" : line
    }

    private func tagColor(_ name: String) -> TodoColor {
        TodoIdentity.tagColor(name, chosen: TodoIdentity.chosenTagColors(todos.me?.tags ?? []))
    }

    /// A default leaves this todo; any other chip opens the picker of its field.
    private func tapChip(_ chip: TodoAddChip) {
        if let key = chip.dismissKey {
            dismissed.insert(key)
        } else if let picker = TodoPicker.of(chipKind: chip.kind) {
            openPicker(picker)
        }
    }

    /// The line is kept as typed, the keyboard goes, and the picker sits where it was. The open
    /// picker's own icon brings the keyboard back.
    private func openPicker(_ next: TodoPicker) {
        pickerStep = nil
        if picker == next {
            withAnimation(.easeOut(duration: 0.2)) { picker = nil }
            titleFocused = true
            return
        }
        titleFocused = false
        TodoKeyboard.dismiss()
        withAnimation(.easeOut(duration: 0.2)) { picker = next }
    }

    private func lowerKeyboard() {
        titleFocused = false
        describeFocused = false
        TodoKeyboard.dismiss()
    }

    // MARK: - The fields

    /// What the pickers change: this sheet's choices, laid over the line and the view when sent.
    private var editing: TodoFieldEditing {
        TodoFieldEditing(
            values: values, today: today, isNew: true, canMove: parent == nil,
            setWhen: { when in
                picks.when = when
                picks.noDay = when == nil
                if when != nil { picks.someday = nil }
            },
            setSomeday: { on in
                picks.someday = on
                if on { picks.when = nil }
            },
            setRepeat: { picks.repeatRule = $0 },
            setDeadline: { deadline in
                picks.deadline = deadline
                picks.noDeadline = deadline == nil
            },
            setHorizon: { picks.horizon = $0 },
            setTag: setTag,
            setList: { picks.list = $0 },
            setDesk: { on in
                picks.desk = on
                if !on { dismissed.insert("desk") } else { dismissed.remove("desk") }
            },
            addNudge: { picks.nudges.append(TodoFieldOps.nudgeSpec($0, id: TodosStore.uuidv7())) },
            removeNudge: { id in
                picks.nudges.removeAll { spec in
                    if case .object(let fields) = spec { return fields["id"] == .string(id) }
                    return false
                }
            })
    }

    /// A tag switched on is picked (or a view's tag taken back); one switched off leaves the
    /// picks, or is a view's tag left off this todo. A tag typed in the line stays with the line.
    private func setTag(_ name: String, _ on: Bool) {
        let lower = name.lowercased()
        let viewTag = (place.defaults?.tags ?? []).first { $0.lowercased() == lower }
        if on {
            if let viewTag, dismissed.contains("tag:\(viewTag)") {
                dismissed.remove("tag:\(viewTag)")
            } else if !picks.tags.contains(where: { $0.lowercased() == lower }) {
                picks.tags.append(name)
            }
        } else if picks.tags.contains(where: { $0.lowercased() == lower }) {
            picks.tags.removeAll { $0.lowercased() == lower }
        } else if let viewTag {
            dismissed.insert("tag:\(viewTag)")
        }
    }

    // MARK: - Sending and closing

    private func send() {
        switch mode {
        case .line: sendLine()
        case .describe: sendPlainWords()
        }
    }

    /// Queues the todo with its picks, its description and its files, and makes the sheet ready
    /// for the next one: an empty line, the view's defaults back, nothing picked.
    private func sendLine() {
        guard let taken = draft.take() else { return }
        let position = deskSection.map { TodoDeskSections.end(of: $0.dividerId, in: todos.deskItems) }
        let changeId = todos.capture(
            text: taken.text, place: place, dismissed: dismissed, parsed: taken.answer, description: details,
            picks: picks, deskPosition: position)
        let todoId = todos.createdTodoId(ofChange: changeId)
        if let todoId {
            for file in files {
                todos.attach(todoId: todoId, name: file.filename, contentType: file.mimeType, data: file.data)
            }
        }
        details = ""
        picks = TodoAddDraft()
        dismissed = []
        files = []
        kept.discard(keptKey)
        pickerStep = nil
        withAnimation(.easeOut(duration: 0.2)) { picker = nil }
        titleFocused = true
        report(changeId, todoId: todoId, words: taken.text)
    }

    /// Says above the sheet how the todo went. A subtask shows in the list behind the sheet, so
    /// only one that did not go through is mentioned.
    private func report(_ changeId: String, todoId: String?, words: String) {
        Task {
            let outcome = await todos.outcome(of: changeId, timeout: 4)
            let next: Notice?
            switch outcome.settlement {
            case .applied:
                next =
                    parent == nil
                    ? Notice(text: "Added · \(outcome.title)", kind: .added(todoId: todoId, changeId: changeId)) : nil
            case .refused:
                next = Notice(text: outcome.message(keeper: .app), kind: .refused(words: words))
            case .waiting:
                next = Notice(text: outcome.message(keeper: .app), kind: .info)
            }
            withAnimation { notice = next }
        }
    }

    private func noticeView(_ notice: Notice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: noticeIcon(notice.kind))
                .foregroundStyle(noticeIsError(notice.kind) ? PaiPalette.Semantic.errorText : PaiPalette.green500)
            Text(notice.text).font(.subheadline).lineLimit(2).foregroundStyle(PaiPalette.Semantic.textStrong)
            Spacer(minLength: 0)
            switch notice.kind {
            case .added(let todoId, let changeId):
                Button("Undo") { undo(changeId) }.font(.subheadline)
                if let todoId {
                    Button("Open") { open(todoId) }.font(.subheadline.weight(.semibold))
                }
            case .refused(let words):
                Button("Put back") {
                    if draft.text.isEmpty { draft.text = words } else { draft.text += " " + words }
                    self.notice = nil
                }
                .font(.subheadline.weight(.semibold))
            case .info:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(RoundedRectangle(cornerRadius: 14).fill(PaiPalette.Semantic.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PaiPalette.Semantic.borderDefault))
        .padding(.horizontal, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func noticeIcon(_ kind: Notice.Kind) -> String {
        switch kind {
        case .added: "checkmark"
        case .info: "tray.and.arrow.down"
        case .refused: "exclamationmark.triangle"
        }
    }

    private func noticeIsError(_ kind: Notice.Kind) -> Bool {
        if case .refused = kind { return true }
        return false
    }

    private func undo(_ changeId: String) {
        Task {
            let outcome = await todos.undo(changeId: changeId)
            withAnimation { notice = outcome.message.map { Notice(text: $0, kind: .info) } }
        }
    }

    /// Opens the todo just added. What is typed for the next one stays kept for when the sheet
    /// is opened again.
    private func open(_ todoId: String) {
        onOpen(todoId)
        dismiss()
    }

    /// ✕, a pull down and a tap outside: with words typed this asks once, an empty sheet closes.
    private func requestClose() {
        if mode == .line, entry.holdsWords || !files.isEmpty {
            lowerKeyboard()
            asking = true
        } else {
            close(discarding: mode == .line)
        }
    }

    private func close(discarding: Bool) {
        if discarding {
            restored = false
            kept.discard(keptKey)
        }
        dismiss()
    }

    // MARK: - Plain words

    @ViewBuilder private var describeBlock: some View {
        if dictation?.ownsBox == true {
            // A live take rewrites the words continuously; the field has no caret to offer then.
            ScrollView {
                Text(plainWords.wrappedValue).font(.title3).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .defaultScrollAnchor(.bottom)
        } else {
            TodoPlainTextEditor(
                text: plainWords, isFocused: describeFocused, font: .preferredFont(forTextStyle: .title3)
            )
            .frame(minHeight: 96, maxHeight: 180)
            .overlay(alignment: .topLeading) {
                if plainWords.wrappedValue.isEmpty {
                    Text("Say or write what needs doing")
                        .font(.title3)
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .disabled(reading)
        }
        describeStatus
        HStack(spacing: 2) {
            Button(action: switchMode) {
                Label("Type one line instead", systemImage: "text.cursor").font(.footnote.weight(.semibold))
            }
            .disabled(reading)
            .accessibilityIdentifier("todo-add-mode")
            Spacer()
            if TodoKeyboard.shared.isUp {
                TodoRailButton(
                    systemImage: "keyboard.chevron.compact.down", label: "Hide keyboard", action: lowerKeyboard)
            }
            TodoRailButton(systemImage: "arrow.up", label: "Send", prominent: true, disabled: !canSend, action: send)
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

    /// Switching keeps the words.
    private func switchMode() {
        let carried = words
        withAnimation(.easeOut(duration: 0.2)) { picker = nil }
        mode = mode == .line ? .describe : .line
        failure = nil
        if mode == .line { draft.text = carried } else { plainWords.wrappedValue = carried }
        titleFocused = mode == .line
        describeFocused = mode == .describe
    }

    private func startDictation(_ dictation: ComposerDictation, _ sttMode: VoiceSttMode) {
        Task { await dictation.toggle(sttMode: sttMode, preText: plainWords.wrappedValue) }
    }

    private func sendPlainWords() {
        guard canSend else { return }
        let text = plainWords.wrappedValue
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

    /// The plain words as one todo, read by the parser like any line, so they are never lost.
    private func addAsTyped() {
        let text = plainWords.wrappedValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let changeId = todos.capture(text: text, place: place, dismissed: dismissed)
        drafts?.clearDraft(key: Self.describeKey)
        failure = nil
        mode = .line
        titleFocused = true
        report(changeId, todoId: todos.createdTodoId(ofChange: changeId), words: text)
    }
}
