import PAIKit
import SwiftUI

/// A diary entry as a card: face, time, context chips, the words. A private entry is fully
/// readable in the person's own view; it only looks different (dashed violet border, a wash).
struct MeEntryCard: View {
    let item: MeDiaryItem
    let presenter: MePresenter
    @Environment(\.colorScheme) private var scheme

    private var report: SelfReport { item.report }

    var body: some View {
        let lock = MeColor.lock(dark: scheme == .dark)
        let words = presenter.words(of: report)
        VStack(alignment: .leading, spacing: 8) {
            meta(lock: lock)
            if let text = words.text {
                Text(text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if report.redacted {
                Text("Private text hidden")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if let refusal = item.refusal {
                Text("Not sent: \(refusal)")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(report.isPrivate ? lock.opacity(0.07) : PaiPalette.Semantic.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            if report.isPrivate {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(lock.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                RoundedRectangle(cornerRadius: 18).stroke(PaiPalette.Semantic.borderDefault, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("me-entry-\(report.id)")
    }

    private func meta(lock: Color) -> some View {
        let words = presenter.words(of: report)
        return HStack(spacing: 8) {
            if let feel = report.feel { FeelFace(feel: feel, size: 20) }
            Text(presenter.entryTime(report))
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            if report.isPrivate {
                Label("Private", systemImage: "lock")
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(lock)
            }
            if let chip = presenter.contextChip(report) { chipView(chip.emoji, chip.text, filled: true) }
            if let chip = presenter.sourceChip(report) { chipView(chip.emoji, chip.text, filled: false) }
            if item.waiting {
                Text("waiting to send")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            if words.text == nil && !report.redacted && item.refusal == nil {
                Text("no words")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func chipView(_ emoji: String, _ text: String, filled: Bool) -> some View {
        HStack(spacing: 4) {
            Text(emoji).font(.system(size: 12))
            Text(text).font(PaiTypography.caption.font).foregroundStyle(PaiPalette.Semantic.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(filled ? PaiPalette.Semantic.insetBackground : .clear, in: Capsule())
        .overlay(Capsule().stroke(filled ? .clear : PaiPalette.Semantic.borderDefault, lineWidth: 1))
        .lineLimit(1)
    }
}

/// A diary entry as a compact row: face, time, two lines of the words with the context in faint
/// text after them, a chevron. A tap opens the full card in place and a second one folds it. An
/// entry still waiting to be sent, or one the server refused, shows its card at once: it has
/// something to say that the row cannot.
struct MeEntryRow: View {
    let item: MeDiaryItem
    let presenter: MePresenter
    @State private var open = false
    @Environment(\.colorScheme) private var scheme

    private var report: SelfReport { item.report }

    var body: some View {
        if open || item.waiting || item.refusal != nil {
            MeEntryCard(item: item, presenter: presenter)
                .contentShape(Rectangle())
                .onTapGesture { if item.refusal == nil && !item.waiting { open = false } }
        } else {
            row
        }
    }

    private var row: some View {
        let lock = MeColor.lock(dark: scheme == .dark)
        return Button {
            open = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let feel = report.feel { FeelFace(feel: feel, size: 16) } else { Color.clear }
                }
                .frame(width: 16, height: 16)
                Text(presenter.entryTime(report))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(width: 38, alignment: .leading)
                    .padding(.top, 1)
                words
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(report.isPrivate ? lock.opacity(0.07) : PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if report.isPrivate {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(lock.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    RoundedRectangle(cornerRadius: 12).stroke(PaiPalette.Semantic.borderDefault, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("me-entry-\(report.id)")
    }

    /// The words, then the context chip in faint text; a stand-in when there are none to show.
    private var words: Text {
        let spoken = presenter.words(of: report)
        var line = AttributedString()
        if let text = spoken.text {
            var main = AttributedString(text)
            main.foregroundColor = PaiPalette.Semantic.textPrimary
            line += main
        } else if report.redacted {
            var hidden = AttributedString("Private text hidden")
            hidden.foregroundColor = PaiPalette.Semantic.textMuted
            line += hidden
        } else {
            var none = AttributedString("no words")
            none.foregroundColor = PaiPalette.Semantic.textFaint
            line += none
        }
        if let chip = presenter.contextChip(report) {
            var context = AttributedString("  \(chip.emoji) \(chip.text)")
            context.foregroundColor = PaiPalette.Semantic.textFaint
            line += context
        }
        return Text(line).font(.system(size: 13.5))
    }
}
