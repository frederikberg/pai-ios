import PAIKit
import SwiftUI

/// A diary entry as a card: face, time, context chips, the words. A private entry is fully
/// readable in the person's own view; it only looks different (dashed violet border, a wash).
struct MeEntryCard: View {
    let item: MeDiaryItem
    var compact = false
    let presenter: MePresenter
    @Environment(\.colorScheme) private var scheme

    private var report: SelfReport { item.report }

    var body: some View {
        let lock = MeColor.lock(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 8) {
            meta(lock: lock)
            if let text = report.text, report.hasWords {
                Text(text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(compact ? 3 : nil)
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
        HStack(spacing: 8) {
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
            if !report.hasWords && !report.redacted && item.refusal == nil {
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
