import PAIKit
import SwiftUI

/// The fields a picker edits, in the order of the rail.
enum TodoPicker: String, Identifiable, CaseIterable {
    case when, horizon, tags, deadline, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .when: "When"
        case .horizon: "Horizon"
        case .tags: "Tags"
        case .deadline: "Deadline"
        case .more: "List and desk"
        }
    }

    var systemImage: String {
        switch self {
        case .when: "calendar"
        case .horizon: "circle.dashed"
        case .tags: "number"
        case .deadline: "target"
        case .more: "ellipsis"
        }
    }

    /// The picker a chip of this kind opens.
    static func of(chipKind kind: String) -> TodoPicker? {
        switch kind {
        case "when", "repeat", "nudge", "clear": .when
        case "horizon": .horizon
        case "tag": .tags
        case "deadline": .deadline
        case "list", "desk": .more
        default: nil
        }
    }
}

/// What the pickers show and change: the fields of an existing todo, or of one not made yet. Both
/// screens hand the same panels one of these, so a field is picked the same way everywhere.
struct TodoFieldEditing {
    var values: TodoEntryValues
    var today: String
    var canEdit = true
    /// A todo not made yet: its nudges exist only in the sheet, and nothing can be snoozed.
    var isNew = false
    /// A subtask lives in its parent's list.
    var canMove = true
    /// Nil clears the day.
    var setWhen: (TodoWhen?) -> Void
    var setSomeday: (Bool) -> Void
    var setRepeat: ([String: PaiJSONValue]?) -> Void
    /// Nil clears the deadline.
    var setDeadline: (TodoDeadline?) -> Void
    var setHorizon: (TodoHorizon) -> Void
    var setTag: (_ name: String, _ on: Bool) -> Void
    var setList: (String) -> Void
    var setDesk: (Bool) -> Void
    var addNudge: (TodoFieldOps.NudgeChoice) -> Void
    var removeNudge: (String) -> Void
    var snoozeNudge: (String) -> Void = { _ in }
    /// Nil where the person's default nudges have nothing to do.
    var useDefaultNudges: (() -> Void)?

    /// Whether the rail marks this picker's icon as holding a value.
    func isSet(_ picker: TodoPicker) -> Bool {
        switch picker {
        case .when: values.when != nil || values.someday || values.repeatRule != nil || !values.nudges.isEmpty
        case .horizon: values.horizon != nil && values.horizon != .whenever
        case .tags: !values.tags.isEmpty
        case .deadline: values.deadline != nil
        case .more: values.onDesk
        }
    }
}

/// One chip of the block: a field's value, in the colour that carries its meaning. A default of
/// the open view is dashed and carries an ✕: a tap leaves it off this todo. Any other chip opens
/// its picker.
struct TodoFieldChip: View {
    let chip: TodoAddChip
    let tagColor: (String) -> TodoColor
    let onTap: () -> Void

    private var label: String { chip.kind == "tag" ? "#" + TodoIdentity.tagLeaf(chip.label) : chip.label }

    private var color: TodoColor? { chip.color ?? (chip.kind == "tag" ? tagColor(chip.label) : nil) }

    private var isDefault: Bool { chip.dismissKey != nil }

    private var icon: String? {
        switch chip.kind {
        case "when": "calendar"
        case "deadline": "target"
        case "repeat": "repeat"
        case "nudge": "bell"
        case "list": "tray.full"
        case "desk": "pin"
        case "clear": "calendar.badge.minus"
        default: nil
        }
    }

    private var foreground: Color {
        if let color { return color.chipText }
        return chip.kind == "when" ? PaiPalette.primary500 : PaiPalette.Semantic.textPrimary
    }

    private var fill: Color {
        if isDefault { return .clear }
        if let color { return color.chip }
        return chip.kind == "when" ? PaiPalette.primary500.opacity(0.16) : PaiPalette.Semantic.raisedSurface
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if chip.kind == "horizon", let color {
                    Circle().strokeBorder(color.swatch, lineWidth: 1.5).frame(width: 10, height: 10)
                } else if let icon {
                    Image(systemName: icon).imageScale(.small)
                }
                Text(label).lineLimit(1)
                if isDefault { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .overlay {
                if isDefault {
                    Capsule().strokeBorder(
                        PaiPalette.Semantic.borderDefault, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDefault ? "\(chip.label), from the view; tap to leave it off" : chip.label)
    }
}

/// The chips of a block, wrapping onto as many lines as they need.
struct TodoFieldChips: View {
    let chips: [TodoAddChip]
    let tagColor: (String) -> TodoColor
    let onTap: (TodoAddChip) -> Void

    var body: some View {
        if !chips.isEmpty {
            TodoFlowLayout(spacing: 6) {
                ForEach(chips) { chip in
                    TodoFieldChip(chip: chip, tagColor: tagColor) { onTap(chip) }
                }
            }
        }
    }
}

/// Lays its children out left to right, starting a new line when one does not fit.
struct TodoFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = place(subviews, in: width)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = place(subviews, in: bounds.width)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, in width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat)
    {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + lineHeight)
    }
}

/// The row of field icons under a block, each in its fixed place: when, horizon, tags, deadline,
/// files, and the rest. The open picker's icon is filled; a field that holds a value is tinted.
/// `trailing` is what the screen adds on the right (describe, keyboard down, send).
struct TodoFieldRail<Trailing: View>: View {
    let editing: TodoFieldEditing
    let open: TodoPicker?
    let onPick: (TodoPicker) -> Void
    /// Nil where files cannot be added.
    var onPhoto: (() -> Void)?
    var onFile: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 2) {
            ForEach([TodoPicker.when, .horizon, .tags, .deadline], id: \.self) { picker in
                icon(picker)
            }
            if let onPhoto, let onFile {
                Menu {
                    Button("Photo", systemImage: "photo", action: onPhoto)
                    Button("File", systemImage: "doc", action: onFile)
                } label: {
                    face("paperclip", active: false, set: false)
                }
                .accessibilityLabel("Add a photo or file")
            }
            icon(.more)
            Spacer(minLength: 4)
            trailing()
        }
    }

    private func icon(_ picker: TodoPicker) -> some View {
        Button {
            onPick(picker)
        } label: {
            face(picker.systemImage, active: open == picker, set: editing.isSet(picker))
        }
        .buttonStyle(.plain)
        .disabled(!editing.canEdit && picker != .more)
        .accessibilityLabel(picker.title)
        .accessibilityAddTraits(open == picker ? .isSelected : [])
    }

    private func face(_ systemImage: String, active: Bool, set: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(active ? Color.white : (set ? PaiPalette.primary500 : PaiPalette.Semantic.textMuted))
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? PaiPalette.primary500 : (set ? PaiPalette.primary500.opacity(0.14) : Color.clear))
            )
            .contentShape(Rectangle())
    }
}

extension TodoFieldRail where Trailing == EmptyView {
    init(
        editing: TodoFieldEditing, open: TodoPicker?, onPick: @escaping (TodoPicker) -> Void,
        onPhoto: (() -> Void)? = nil, onFile: (() -> Void)? = nil
    ) {
        self.init(editing: editing, open: open, onPick: onPick, onPhoto: onPhoto, onFile: onFile) { EmptyView() }
    }
}

/// A round control of the rail's right side.
struct TodoRailButton: View {
    let systemImage: String
    let label: String
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 17 : 18, weight: prominent ? .bold : .medium))
                .foregroundStyle(prominent ? Color.white : PaiPalette.Semantic.textMuted)
                .frame(width: 40, height: 40)
                .background(
                    Circle().fill(
                        prominent
                            ? (disabled ? PaiPalette.Semantic.raisedSurface : PaiPalette.primary500) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// Files held for a todo not made yet, or queued for one: a thumbnail or a name each, with an ✕
/// where it can still be left out.
struct TodoHeldFiles: View {
    struct Item: Identifiable {
        let id: String
        let name: String
        let image: UIImage?
    }

    let items: [Item]
    /// Opens a file in the viewer, by its id.
    var onOpen: ((String) -> Void)?
    var onRemove: ((String) -> Void)?

    /// The pixels a thumbnail is made at: the face's points at the densest screen.
    static let thumbnailPixels = CGSize(width: 162, height: 162)

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if items.count > 3 {
                    Text("\(items.count) files")
                        .font(.caption)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(items) { item in
                            Button {
                                onOpen?(item.id)
                            } label: {
                                face(item)
                            }
                            .buttonStyle(.plain)
                            .disabled(onOpen == nil)
                            .accessibilityLabel("Open \(item.name)")
                            .overlay(alignment: .topTrailing) { remove(item) }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
                .frame(height: 62)
            }
        }
    }

    @ViewBuilder private func remove(_ item: Item) -> some View {
        if let onRemove {
            Button {
                onRemove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, PaiPalette.surface600)
                    .frame(width: 30, height: 30, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 7, y: -7)
            .accessibilityLabel("Leave out \(item.name)")
        }
    }

    @ViewBuilder private func face(_ item: Item) -> some View {
        if let image = item.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        } else {
            Label(item.name, systemImage: "paperclip")
                .font(.footnote)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 54)
                .frame(maxWidth: 180)
                .background(RoundedRectangle(cornerRadius: 10).fill(PaiPalette.Semantic.raisedSurface))
                .contentShape(Rectangle())
        }
    }
}
