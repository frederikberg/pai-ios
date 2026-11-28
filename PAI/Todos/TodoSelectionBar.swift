import PAIKit
import SwiftUI

/// What can be done to the selected todos, each as one change with one Undo: a bar on the bottom
/// of the page that says how many are selected, widens the selection to every row or ends it, and
/// carries the actions. A field's picker opens inside the bar, under the actions, and stays for
/// further picks; the selection is kept until it is ended. The bar tells the toasts how tall it
/// is, so the Undo toast stands above it.
struct TodoSelectionBar: View {
    let count: Int
    /// How many todos the page shows, which "All" selects.
    let visibleCount: Int
    /// None of the selected is open: the tick reopens.
    let reopens: Bool
    let picker: TodoPicker?
    let editing: TodoFieldEditing
    let onAll: () -> Void
    let onEnd: () -> Void
    let onAction: (TodoBulk.Action) -> Void
    let onPick: (TodoPicker?) -> Void

    @Environment(ToastCenter.self) private var toasts
    @State private var toastOwner = UUID().uuidString

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            summary
            actions
            if let picker {
                Divider()
                TodoPickerPanel(picker: picker, editing: editing) { onPick(nil) }
                    .id(picker)
                    .frame(height: 300)
            }
        }
        .background(PaiPalette.Semantic.panelBackground.ignoresSafeArea(edges: .bottom))
        .background(
            GeometryReader { proxy in
                Color.clear.toastsStandAbove(Double(proxy.size.height), owner: toastOwner, toasts: toasts)
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected todos")
    }

    private var summaryText: String { count == 0 ? "Tap todos to select them" : "\(count) selected" }

    private var summary: some View {
        HStack(spacing: 12) {
            Text(summaryText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PaiPalette.Semantic.textStrong)
            Spacer()
            Button("All \(visibleCount)", action: onAll)
                .font(.subheadline)
                .disabled(visibleCount == 0 || count == visibleCount)
            Button("Done", action: onEnd)
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel("End selecting")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 40)
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                action(reopens ? "Reopen" : "Complete", "checkmark.circle") { onAction(TodoBulk.Action.complete) }
                action("Desk", "pin") { onAction(TodoBulk.Action.desk) }
                pickerAction("Day", TodoPicker.when)
                pickerAction("Horizon", TodoPicker.horizon)
                pickerAction("Tag", TodoPicker.tags)
                pickerAction("Move", TodoPicker.more)
                action("Delete", "trash", tint: PaiPalette.Semantic.errorText) { onAction(TodoBulk.Action.delete) }
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 6)
    }

    private func pickerAction(_ title: String, _ target: TodoPicker) -> some View {
        action(title, target.systemImage, active: picker == target) { onPick(picker == target ? nil : target) }
    }

    private func action(
        _ title: String, _ systemImage: String, tint: Color = PaiPalette.Semantic.textPrimary, active: Bool = false,
        run: @escaping () -> Void
    ) -> some View {
        Button(action: run) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .medium))
                Text(title).font(.caption2)
            }
            .foregroundStyle(active ? Color.white : tint)
            .frame(minWidth: 50, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? PaiPalette.primary500 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.4 : 1)
    }
}
