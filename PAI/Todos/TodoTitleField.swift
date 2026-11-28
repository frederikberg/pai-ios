import PAIKit
import SwiftUI
import UIKit

/// A todo's title, new or existing, as one field: it grows line by line up to `maxLines` and then
/// scrolls inside itself with the newest line in view, Return never makes a line (it sends or
/// saves, whatever `onReturn` does), a pasted picture is handed on as a file instead of refused,
/// the words read as fields are marked in their field's colour, and the words that will not stay
/// in the title are drawn dimmed.
///
/// A text view rather than SwiftUI's vertical `TextField`, whose Return key inserts a line break
/// and never reports a submit.
struct TodoTitleField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// UTF-16 ranges of `text` drawn dimmed: the part that moves to the description.
    var dimmed: [Range<Int>] = []
    /// Words read as fields, marked where they sit.
    var marks: [Mark] = []
    var isFocused: Bool
    var isEditable = true
    var maxLines = 5
    var returnKey: UIReturnKeyType = .send
    /// A strip on top of the keyboard with an @ key, for a line that reads `@tag`: the keyboard's
    /// own @ is a layer away, and the keyboard that has one in reach has no Return key.
    var showsTagKey = false
    var onFocusChange: (Bool) -> Void = { _ in }
    var onReturn: () -> Void = {}
    var onPasteImages: ([PastedImage]) -> Void = { _ in }

    /// A UTF-16 range of the text with the colours of the field it was read as.
    struct Mark: Equatable {
        let range: Range<Int>
        let fill: UIColor
        let ink: UIColor
    }

    static let font = UIFont.preferredFont(forTextStyle: .title3).withWeight(.semibold)

    func makeUIView(context: Context) -> PasteAwareTextView {
        let view = PasteAwareTextView()
        view.delegate = context.coordinator
        view.font = Self.font
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onPasteImages = { [weak coordinator = context.coordinator] images in
            coordinator?.parent.onPasteImages(images)
            return nil
        }
        let label = UILabel()
        label.font = Self.font
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
        ])
        context.coordinator.placeholder = label
        if showsTagKey { view.inputAccessoryView = context.coordinator.makeTagKeyBar(for: view) }
        return view
    }

    func updateUIView(_ view: PasteAwareTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.isEditable = isEditable
        view.returnKeyType = returnKey
        context.coordinator.placeholder?.text = placeholder
        context.coordinator.placeholder?.isHidden = !text.isEmpty
        context.coordinator.paint(view)
        // The keyboard follows a change of `isFocused`, never its standing value: while another
        // field takes the keyboard this one is told a turn later, and asking again meanwhile
        // would take it straight back.
        if isFocused != context.coordinator.appliedFocus {
            context.coordinator.appliedFocus = isFocused
            if isFocused, !view.isFirstResponder {
                // A view not yet in a window cannot take the keyboard; ask once it is.
                if view.window != nil {
                    view.becomeFirstResponder()
                } else {
                    DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
                }
            } else if !isFocused, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
        view.invalidateIntrinsicContentSize()
    }

    /// As tall as its words up to `maxLines`; beyond that the field scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteAwareTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let wanted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let inset = uiView.textContainerInset
        let limit = (Self.font.lineHeight * CGFloat(maxLines) + inset.top + inset.bottom).rounded(.up)
        let scrolls = wanted > limit
        if uiView.isScrollEnabled != scrolls { uiView.isScrollEnabled = scrolls }
        return CGSize(width: width, height: min(wanted, limit))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TodoTitleField
        var placeholder: UILabel?
        /// The `isFocused` the keyboard was last moved for.
        var appliedFocus: Bool?

        init(parent: TodoTitleField) {
            self.parent = parent
        }

        private weak var field: UITextView?

        func makeTagKeyBar(for view: UITextView) -> UIToolbar {
            field = view
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
            let key = UIBarButtonItem(title: "@", style: .plain, target: self, action: #selector(typeTagMarker))
            let face: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .semibold)]
            key.setTitleTextAttributes(face, for: .normal)
            key.setTitleTextAttributes(face, for: .highlighted)
            key.width = 56
            key.accessibilityLabel = "At sign, starts a tag"
            bar.items = [key, UIBarButtonItem(systemItem: .flexibleSpace)]
            bar.sizeToFit()
            return bar
        }

        /// Types the @ at the caret, set off from the word before it so the tag reads as one.
        @objc private func typeTagMarker() {
            guard let field, field.markedTextRange == nil else { return }
            let caret = field.selectedRange.location
            let before =
                caret > 0 ? (field.text as NSString).substring(with: NSRange(location: caret - 1, length: 1)) : " "
            let needsSpace = before.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) }
            field.insertText(needsSpace ? " @" : "@")
            textViewDidChange(field)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholder?.isHidden = !textView.text.isEmpty
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else {
                // What is typed next to a marked word is plain until the parser says otherwise.
                textView.typingAttributes = [
                    .font: TodoTitleField.font, .foregroundColor: UIColor(PaiPalette.Semantic.textStrong),
                ]
                return true
            }
            parent.onReturn()
            return false
        }

        // Told a turn later: the keyboard can come and go from inside a view update, where
        // changing what the screen shows is not allowed.
        func textViewDidBeginEditing(_ textView: UITextView) {
            appliedFocus = true
            Task { @MainActor in self.parent.onFocusChange(true) }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            appliedFocus = false
            Task { @MainActor in self.parent.onFocusChange(false) }
        }

        /// Colours the words: the title's own bright, a word read as a field in its field's
        /// colours, the part that moves dimmed. Left alone while a word is still being composed,
        /// which a change of attributes would end.
        func paint(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            let storage = view.textStorage
            let whole = NSRange(location: 0, length: storage.length)
            let bright = UIColor(PaiPalette.Semantic.textStrong)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: bright, range: whole)
            storage.removeAttribute(.backgroundColor, range: whole)
            for mark in parent.marks where !mark.range.isEmpty && mark.range.upperBound <= storage.length {
                let range = NSRange(location: mark.range.lowerBound, length: mark.range.count)
                storage.addAttribute(.backgroundColor, value: mark.fill, range: range)
                storage.addAttribute(.foregroundColor, value: mark.ink, range: range)
            }
            for range in parent.dimmed where range.upperBound <= storage.length {
                storage.addAttribute(
                    .foregroundColor, value: UIColor(PaiPalette.Semantic.textFaint),
                    range: NSRange(location: range.lowerBound, length: range.count))
            }
            storage.endEditing()
            view.typingAttributes[.foregroundColor] = bright
        }
    }
}

extension UIFont {
    fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// How tall the keyboard last was, so a picker that takes its place is exactly as tall and the
/// sheet above it does not move.
@Observable
@MainActor
final class TodoKeyboard {
    static let shared = TodoKeyboard()

    /// The keyboard's height the last time it was up, including the home indicator's strip.
    private(set) var lastHeight: CGFloat = 336
    private(set) var isUp = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            let height = frame?.height ?? 0
            Task { @MainActor in TodoKeyboard.shared.noteShown(height: height) }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in TodoKeyboard.shared.isUp = false }
        }
    }

    private func noteShown(height: CGFloat) {
        isUp = true
        if height > 200 { lastHeight = height }
    }

    /// The strip under the screen's content the home indicator takes, which the keyboard's own
    /// height includes.
    static var homeIndicatorInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }?.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    /// Puts the keyboard down, whichever field has it.
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
