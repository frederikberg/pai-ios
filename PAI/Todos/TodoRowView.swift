import PAIKit
import SwiftUI

/// One todo in a page or on the desk: its tick circle (a dot in it while the todo is on the desk),
/// the title, one quiet line of what else it carries, and on the right its day with its deadline
/// under it, each in the colour of how near it is. A subtask sits indented under its parent; a row
/// with subtasks has a chevron that opens them. While todos are being selected the circle is the
/// selection mark.
struct TodoRowView: View {
    let model: TodoRowModel
    var depth = 0
    var expandable = false
    var expanded = false
    /// A checklist's row: one line, no description.
    var compact = false
    var onTick: () -> Void = {}
    var onToggleExpanded: () -> Void = {}
    /// Tapping the row outside its circle and chevron opens the todo.
    var onOpen: (() -> Void)?
    /// Set while several todos are being selected: whether this one is. The circle then shows
    /// that instead of ticking, and a tap anywhere on the row switches it.
    var selected: Bool?
    var onSelect: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            chevron
            if let selected {
                Button(action: onSelect) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: compact ? 24 : 22))
                        .foregroundStyle(selected ? PaiPalette.primary500 : PaiPalette.Semantic.textFaint)
                        .padding(.top, 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selected ? "Selected" : "Not selected")
            } else {
                tickButton
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title)
                        .font(.body)
                        .foregroundStyle(titleColor)
                        .strikethrough(model.done)
                        .lineLimit(compact ? 1 : 2)
                    if !compact, hasMeta { metaLine }
                }
                Spacer(minLength: 4)
                dates
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selected != nil { onSelect() } else { onOpen?() }
            }
        }
        .padding(.leading, CGFloat(depth) * 22)
        .padding(.vertical, compact ? 6 : 4)
        .contentShape(Rectangle())
    }

    private var tickButton: some View {
        Button(action: onTick) {
            TodoTickCircle(mark: model.horizon, done: model.done, onDesk: model.onDesk, size: compact ? 24 : 22)
                .padding(.top, 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.done ? "Reopen" : "Done")
        .accessibilityValue(model.onDesk ? "On your desk" : "")
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

    /// The day, and under it the deadline behind its own icon, so days line up down the page.
    @ViewBuilder private var dates: some View {
        if model.day != nil || model.deadline != nil {
            VStack(alignment: .trailing, spacing: 3) {
                if let day = model.day {
                    Text(day.label).foregroundStyle(Self.lightColor(day.light))
                }
                if let deadline = model.deadline {
                    HStack(spacing: 3) {
                        Image(systemName: "target").imageScale(.small)
                        Text(deadline.label)
                    }
                    .foregroundStyle(Self.lightColor(deadline.light))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Deadline \(deadline.label)")
                }
            }
            .font(.footnote)
            .lineLimit(1)
            .fixedSize()
            .padding(.top, 2)
        }
    }

    private var titleColor: Color {
        model.done ? PaiPalette.Semantic.textFaint : PaiPalette.Semantic.textStrong
    }

    private var hasMeta: Bool {
        model.preview != nil || model.subtasks != nil || model.checklist != nil || !model.tags.isEmpty
            || model.listName != nil || model.repeats || model.hasNudge
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if let preview = model.preview {
                Text(preview).lineLimit(1).truncationMode(.tail)
            }
            if let subtasks = model.subtasks {
                Text(subtasks).monospacedDigit().accessibilityLabel("\(subtasks) subtasks finished")
            }
            if model.repeats {
                Image(systemName: "repeat").accessibilityLabel("Repeats")
            }
            if model.hasNudge {
                Image(systemName: "bell").accessibilityLabel("Has a nudge")
            }
            if let checklist = model.checklist {
                Label(checklist, systemImage: "checklist").labelStyle(.titleAndIcon).monospacedDigit()
                    .accessibilityLabel("\(checklist) boxes ticked")
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

    static func lightColor(_ light: TodoDates.Light) -> Color {
        switch light {
        case .late: PaiPalette.Semantic.errorText
        case .today: PaiPalette.Semantic.warningText
        case .week: PaiPalette.primary500
        case .later: PaiPalette.Semantic.textMuted
        }
    }
}
