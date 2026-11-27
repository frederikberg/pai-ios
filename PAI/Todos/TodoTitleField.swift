import PAIKit
import SwiftUI
import UIKit

/// A todo's title, new or existing, as one field: it grows line by line up to `maxLines` and then
/// scrolls inside itself with the newest line in view, Return never makes a line (it sends or
/// saves, whatever `onReturn` does), a pasted picture is handed on as a file instead of refused,
/// and the words that will not stay in the title are drawn dimmed.
///
/// A text view rather than SwiftUI's vertical `TextField`, whose Return key inserts a line break
/// and never reports a submit.
struct TodoTitleField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// UTF-16 ranges of `text` drawn dimmed: the part that moves to the description.
    var dimmed: [Range<Int>] = []
    var isFocused: Bool
    var isEditable = true
    var maxLines = 5
    var returnKey: UIReturnKeyType = .send
    var onFocusChange: (Bool) -> Void = { _ in }
    var onReturn: () -> Void = {}
    var onPasteImages: ([PastedImage]) -> Void = { _ in }

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

        init(parent: TodoTitleField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholder?.isHidden = !textView.text.isEmpty
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            parent.onReturn()
            return false
        }

        // Told a turn later: the keyboard can come and go from inside a view update, where
        // changing what the screen shows is not allowed.
        func textViewDidBeginEditing(_ textView: UITextView) {
            Task { @MainActor in self.parent.onFocusChange(true) }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            Task { @MainActor in self.parent.onFocusChange(false) }
        }

        /// Colours the words: the title's own bright, the part that moves dimmed. Left alone
        /// while a word is still being composed, which a change of attributes would end.
        func paint(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            let storage = view.textStorage
            let whole = NSRange(location: 0, length: storage.length)
            let bright = UIColor(PaiPalette.Semantic.textStrong)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: bright, range: whole)
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
