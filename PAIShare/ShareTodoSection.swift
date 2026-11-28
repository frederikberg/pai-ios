import PAIKit
import SwiftUI

/// "Todo" in the share sheet: the shared text (or the link) as a todo's words, editable, with
/// the link attached and the shared photos and files as its files. What the server's parser reads
/// in the words applies, as in the app. A todo the server did not take stays here with its words
/// and a Try again; nothing waits elsewhere.
struct ShareTodoSection: View {
    @Bindable var todo: ShareTodoStore
    let close: () -> Void

    var body: some View {
        Section("New todo") {
            if case .added(let outcome) = todo.phase {
                Label(outcome.message(keeper: .shareSheet), systemImage: "checkmark.circle")
                    .task {
                        try? await Task.sleep(for: .seconds(1.2))
                        close()
                    }
            } else {
                TextField(placeholder, text: $todo.text, axis: .vertical)
                    .lineLimit(1...4)
                    .disabled(todo.isMade)
                if let link = todo.link {
                    Label(link, systemImage: "link").font(.footnote).lineLimit(1).truncationMode(.middle)
                }
                if !todo.files.isEmpty {
                    Label(ShareWording.files(todo.files), systemImage: "paperclip").font(.footnote)
                }
                if let problem = todo.problem {
                    Text(problem).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await todo.add() }
                } label: {
                    if todo.phase == .sending {
                        ProgressView()
                    } else if todo.problem != nil {
                        Label("Try again", systemImage: "arrow.clockwise")
                    } else {
                        Label("Add todo", systemImage: "checkmark.circle")
                    }
                }
                .disabled(!todo.canAdd)
                .accessibilityIdentifier("share-add-todo")
            }
        }
    }

    private var placeholder: String {
        if !todo.files.isEmpty { return "New todo with \(ShareWording.files(todo.files))" }
        return todo.link == nil ? "New todo" : "New todo (the link is attached)"
    }
}

/// "Note" in the share sheet: a new note named here, holding the shared text, the link and the
/// shared photos and files. A note the server did not take stays here with a Try again.
struct ShareNoteSection: View {
    @Bindable var note: ShareNoteStore
    let close: () -> Void

    var body: some View {
        Section("New note") {
            if case .added(let name) = note.phase {
                Label("Created \u{201C}\(name)\u{201D}.", systemImage: "checkmark.circle")
                    .task {
                        try? await Task.sleep(for: .seconds(1.2))
                        close()
                    }
            } else {
                TextField("Name of the note", text: $note.name)
                if let text = note.text {
                    Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                if let link = note.link {
                    Label(link, systemImage: "link").font(.footnote).lineLimit(1).truncationMode(.middle)
                }
                if !note.files.isEmpty {
                    Label(ShareWording.files(note.files), systemImage: "paperclip").font(.footnote)
                }
                if case .failed(let message) = note.phase {
                    Text("Not created: \(message)").font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await note.add() }
                } label: {
                    if note.phase == .sending {
                        ProgressView()
                    } else if case .failed = note.phase {
                        Label("Try again", systemImage: "arrow.clockwise")
                    } else {
                        Label("Create note", systemImage: "note.text.badge.plus")
                    }
                }
                .disabled(!note.canAdd)
                .accessibilityIdentifier("share-add-note")
            }
        }
    }
}

enum ShareWording {
    /// The shared files in a few words: the one file's name, or how many there are.
    static func files(_ files: [ShareItem]) -> String {
        files.count == 1 ? (files.first?.name ?? "1 file") : "\(files.count) files"
    }
}
