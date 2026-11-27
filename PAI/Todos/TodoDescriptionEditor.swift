import PAIKit
import SwiftUI
import UIKit

/// Plain text, typed fast: the system's own text view with nothing between the keys and the
/// words, so the caret stays where it is, double space makes a full stop and long text does not
/// lag. A bar above the keyboard hides it.
struct TodoPlainTextEditor: UIViewRepresentable {
    @Binding var text: String
    var isFocused = false
    var isEditable = true
    var font = UIFont.preferredFont(forTextStyle: .body)

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = font
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = UIColor(PaiPalette.Semantic.textStrong)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.inputAccessoryView = context.coordinator.makeKeyboardBar()
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        // Only a change made elsewhere is written into the view: setting the text it already
        // holds would move the caret to the end on every keystroke.
        if view.text != text { view.text = text }
        view.isEditable = isEditable
        if isFocused, !context.coordinator.tookFocus, view.window != nil {
            context.coordinator.tookFocus = true
            view.becomeFirstResponder()
        } else if isFocused, !context.coordinator.tookFocus {
            context.coordinator.tookFocus = true
            DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
        } else if !isFocused {
            context.coordinator.tookFocus = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TodoPlainTextEditor
        /// The keyboard was asked for once for this focus; the person may put it down again.
        var tookFocus = false

        init(parent: TodoPlainTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func makeKeyboardBar() -> UIToolbar {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
            let hide = UIBarButtonItem(
                image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: self,
                action: #selector(hideKeyboard))
            hide.accessibilityLabel = "Hide keyboard"
            bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), hide]
            bar.sizeToFit()
            return bar
        }

        @objc private func hideKeyboard() {
            TodoKeyboard.dismiss()
        }
    }
}

/// The description of a todo not made yet: written here, kept with the sheet's draft, sent with
/// the todo.
struct TodoDraftDescriptionSheet: View {
    @Binding var text: String
    /// The todo's title so far, under the heading.
    let subtitle: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TodoPlainTextEditor(text: $text, isFocused: true)
                .padding(.horizontal, 16)
                .toolbar {
                    ToolbarItem(placement: .principal) { TodoDescriptionHeading(subtitle: subtitle) }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .fixtureFact("todosDescriptionEditor", "draft")
    }
}

struct TodoDescriptionHeading: View {
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            Text("Description").font(.headline)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(PaiPalette.Semantic.textMuted).lineLimit(1)
            }
        }
    }
}

/// A todo's description, written: plain text that saves itself a moment after typing stops and
/// when the screen is left, and says only whether it is saved. It is read formatted on the todo's
/// screen, not while writing.
struct TodoDescriptionScreen: View {
    let todo: Todo
    let canEdit: Bool

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// Begun once the whole description has been read.
    @State private var saver: TodoBodySaver?

    /// The todo as last read whole; a row carries only the first line of its description.
    private var read: Todo? {
        environment.todos.details[todo.id]?.todo ?? (todo.body != nil ? todo : nil)
    }

    var body: some View {
        Group {
            if let saver {
                editor(saver)
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { TodoDescriptionHeading(subtitle: todo.title) }
            ToolbarItem(placement: .confirmationAction) {
                HStack(spacing: 10) {
                    if let saver { status(saver.state) }
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: begin)
        .onChange(of: read?.bodyHash) { begin() }
        // Leaving by Done, Back or a swipe keeps what was typed.
        .onDisappear { if let saver { Task { await saver.save() } } }
        .fixtureFact("todosDescriptionEditor", saver == nil ? "loading" : "open")
    }

    @ViewBuilder private func editor(_ saver: TodoBodySaver) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .refused(let message) = saver.state {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not saved: \(message) Your words are still here.")
                        .font(.footnote)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                    Button("Save mine over it") { Task { await saver.save(overwriting: true) } }
                        .font(.footnote.weight(.semibold))
                }
            }
            TodoPlainTextEditor(
                text: Binding(get: { saver.text }, set: { saver.text = $0 }), isFocused: canEdit, isEditable: canEdit)
        }
        .padding(.horizontal, 16)
        .task(id: saver.text) {
            guard canEdit, saver.state == .unsaved else { return }
            try? await Task.sleep(for: .seconds(TodoBodySaver.pauseSeconds))
            guard !Task.isCancelled else { return }
            await saver.save()
        }
    }

    @ViewBuilder private func status(_ state: TodoBodySaver.Status) -> some View {
        switch state {
        case .saved:
            Label("Saved", systemImage: "checkmark").labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(PaiPalette.Semantic.textMuted)
        case .saving, .unsaved:
            Text("Saving…").font(.caption).foregroundStyle(PaiPalette.Semantic.textMuted)
        case .waiting:
            Text("Kept on this iPhone").font(.caption).foregroundStyle(PaiPalette.Semantic.warningText)
        case .refused:
            Text("Not saved").font(.caption).foregroundStyle(PaiPalette.Semantic.errorText)
        }
    }

    private func begin() {
        guard saver == nil, let read else { return }
        saver = TodoBodySaver(read, store: environment.todos)
    }
}

/// A todo's description as the Notes preview draws markdown: headings, lists and task boxes,
/// links and code. Its files are named; they open from the Files section.
struct TodoDescriptionView: View {
    let text: String

    /// A description longer than this many blocks is read on its own screen.
    static let blocksShown = 12

    var body: some View {
        let document = NotePreviewDocument(body: text, nameToId: [:])
        VStack(alignment: .leading, spacing: 8) {
            ForEach(document.items.prefix(Self.blocksShown)) { item in
                NotePreviewBlockView(
                    block: item.block, taskBase: item.firstTask, attachments: document.attachments, containerId: nil)
            }
            if document.items.count > Self.blocksShown {
                Text("More…").font(.footnote).foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .environment(\.previewNamesFilesOnly, true)
    }
}
