import PAIKit
import SwiftUI

/// One todo in a page or on the desk: its tick circle, the title with its date, and one quiet line
/// of what else it carries. A subtask sits indented under its parent; a row with subtasks has a
/// chevron that opens them.
struct TodoRowView: View {
    let model: TodoRowModel
    var depth = 0
    var expandable = false
    var expanded = false
    /// A checklist's row: one line, no description.
    var compact = false
    var onTick: () -> Void = {}
    var onToggleExpanded: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            chevron
            Button(action: onTick) {
                TodoTickCircle(mark: model.horizon, done: model.done, size: compact ? 24 : 22)
                    .padding(.top, 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.done ? "Reopen" : "Done")
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                if !compact, hasMeta { metaLine }
            }
        }
        .padding(.leading, CGFloat(depth) * 22)
        .padding(.vertical, compact ? 6 : 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var chevron: some View {
        if expandable {
            Button(action: onToggleExpanded) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .frame(width: 14, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide subtasks" : "Show subtasks")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.title)
                .font(.body)
                .foregroundStyle(titleColor)
                .strikethrough(model.done)
                .lineLimit(compact ? 1 : 2)
            Spacer(minLength: 4)
            if let date = model.date {
                Text(date.label)
                    .font(.footnote)
                    .foregroundStyle(Self.toneColor(date.tone))
                    .lineLimit(1)
            }
        }
    }

    private var titleColor: Color {
        model.done ? PaiPalette.Semantic.textFaint : PaiPalette.Semantic.textStrong
    }

    private var hasMeta: Bool {
        model.preview != nil || model.checklist != nil || model.inside > 0 || !model.tags.isEmpty
            || model.listName != nil || model.repeats
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if let preview = model.preview {
                Text(preview).lineLimit(1).truncationMode(.tail)
            }
            if model.repeats {
                Image(systemName: "repeat")
            }
            if let checklist = model.checklist {
                Text(checklist).monospacedDigit()
            }
            if model.inside > 0 {
                Text("\(model.inside) inside")
            }
            ForEach(model.tags, id: \.name) { tag in
                TodoTagChip(name: tag.name, color: tag.color)
            }
            if model.moreTags > 0 {
                Text("+\(model.moreTags)")
            }
            if let listName = model.listName {
                listLabel(listName)
            }
        }
        .font(.footnote)
        .foregroundStyle(PaiPalette.Semantic.textMuted)
    }

    private func listLabel(_ name: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill((model.listColor ?? .slate).swatch).frame(width: 6, height: 6)
            Text(name).lineLimit(1)
        }
    }

    static func toneColor(_ tone: TodoDates.Tone) -> Color {
        switch tone {
        case .neutral: PaiPalette.Semantic.textMuted
        case .today: PaiPalette.primary500
        case .soon: PaiPalette.Semantic.warningText
        case .late: PaiPalette.Semantic.errorText
        }
    }
}
