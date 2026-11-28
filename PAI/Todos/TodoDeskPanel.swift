import PAIKit
import SwiftUI

/// The desk above a page, in one of its three states (`TodoDeskMode`): a bar that says how much is
/// on it and what comes first; the split, the desk over the list, each with its own scroll and the
/// desk at most half the height; or the desk alone, with the list folded to one line under it.
/// Each step is one press, and a tap on the desk's own bar, anywhere that is not a control,
/// folds it and opens it again as it was. A todo reaches the desk by swiping its row right.
struct TodoDeskPanel<ListContent: View>: View {
    let todos: TodosStore
    @Binding var mode: TodoDeskMode
    /// The page's title and count, for the line the list folds to.
    let listTitle: String
    let listCount: Int?
    let rowModel: (Todo) -> TodoRowModel
    let onTick: (String) -> Void
    let onOpen: (String) -> Void
    /// Opens the add sheet for a todo that lands at the end of this section of the desk.
    var onAddHere: (TodoAddDeskSection) -> Void = { _ in }
    @ViewBuilder let list: () -> ListContent

    @Environment(ToastCenter.self) private var toasts
    /// The cards can be dragged into a new order, sections included.
    @State private var arranging = false
    /// The section being named: a new one (nil id) or one renamed.
    @State private var naming: (id: String?, title: String)?
    /// How the desk was open before it was folded, which a tap on the folded bar brings back.
    @State private var lastOpen = TodoDeskMode.split

    /// The desk as it is drawn: sections, and the cards whose todo is at hand. Every index a
    /// row is moved by counts these, so a card that cannot be drawn never shifts a move.
    private var shown: [TodoDeskItem] {
        todos.deskItems.filter { $0.kind == .divider || todos.todos[$0.todoId ?? ""] != nil }
    }

    private var cards: [TodoDeskItem] { shown.filter { $0.kind == .todo } }

    private func fold() {
        lastOpen = mode
        withAnimation(.snappy) { mode = .bar }
    }

    /// The split's share of the height for the desk: what its items need, at most about half.
    private var deskShare: CGFloat { min(0.48, 0.12 + CGFloat(shown.count) * 0.075) }

    private var firstOpenTitle: String? {
        cards.lazy.compactMap { todos.todos[$0.todoId ?? ""] }.first { $0.status == .open }?.title
    }

    var body: some View {
        switch mode {
        case .bar:
            VStack(spacing: 0) {
                bar
                list()
            }
        case .split:
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    deskBlock
                        .frame(height: geometry.size.height * deskShare)
                    list()
                }
            }
        case .desk:
            VStack(spacing: 0) {
                deskBlock
                foldedList
            }
        }
    }

    private var bar: some View {
        Button {
            withAnimation(.snappy) { mode = lastOpen }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pin").foregroundStyle(PaiPalette.primary500)
                Text("Desk").font(.subheadline.weight(.semibold)).foregroundStyle(PaiPalette.Semantic.textStrong)
                    .fixedSize()
                Text("\(cards.count)").font(.subheadline).monospacedDigit().foregroundStyle(
                    PaiPalette.Semantic.textFaint
                )
                .fixedSize()
                Text(barLine).font(.subheadline).foregroundStyle(PaiPalette.Semantic.textMuted).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(PaiPalette.Semantic.insetBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PaiPalette.Semantic.borderDefault))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .accessibilityLabel("Desk, \(cards.count) \(cards.count == 1 ? "todo" : "todos"): open")
    }

    private var barLine: String {
        if let firstOpenTitle { return firstOpenTitle }
        return cards.isEmpty ? "Swipe a todo right to put it here" : ""
    }

    private var deskBlock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "pin").foregroundStyle(PaiPalette.primary500)
                // The bar sits beside the side rail on a phone: the name and count never give up
                // their width, and the less used actions live in one menu.
                Text("Desk").font(.subheadline.weight(.semibold)).foregroundStyle(PaiPalette.Semantic.textStrong)
                    .lineLimit(1).fixedSize()
                Text("\(cards.count)").font(.caption).monospacedDigit().foregroundStyle(PaiPalette.Semantic.textFaint)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                if arranging {
                    Button("Done") { withAnimation(.snappy) { arranging = false } }
                        .lineLimit(1).fixedSize()
                }
                actionsMenu
                Button {
                    withAnimation(.snappy) { mode = mode == .desk ? .split : .desk }
                } label: {
                    Image(
                        systemName: mode == .desk
                            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                    )
                    .frame(width: 36, height: 32)
                }
                .accessibilityLabel(mode == .desk ? "Show the list too" : "Only the desk")
                Button(action: fold) {
                    Image(systemName: "chevron.up").frame(width: 36, height: 32)
                }
                .accessibilityLabel("Fold the desk")
            }
            .font(.subheadline)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            // The name and the empty width fold the desk too; the controls keep their own taps.
            .contentShape(Rectangle())
            .onTapGesture { if !arranging { fold() } }
            deskList
        }
        .background(PaiPalette.Semantic.insetBackground)
        .overlay(alignment: .bottom) { Divider() }
        .alert(
            naming?.id == nil ? "New section" : "Rename the section",
            isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
        ) {
            TextField("Title", text: Binding(get: { naming?.title ?? "" }, set: { naming?.title = $0 }))
            Button("Save") { saveSection() }
            Button("Cancel", role: .cancel) { naming = nil }
        }
        .task { arrangeForFixture() }
        .fixtureFact(
            "todosDeskAddHere", String(deskRows.filter { if case .addHere = $0 { true } else { false } }.count))
    }

    /// A new section goes last, as on the web; a renamed one keeps its place.
    private func saveSection() {
        guard let naming else { return }
        let title = naming.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.naming = nil
        guard !title.isEmpty else { return }
        if let id = naming.id {
            todos.submit([TodoFieldOps.deskSection(id: id, title: title, position: nil)])
        } else {
            todos.submit([TodoFieldOps.deskSection(id: TodosStore.uuidv7(), title: title)])
        }
    }

    private func arrangeForFixture() {
        #if DEBUG
            if PaiFixtureLaunch.arrangesTodosDesk() { arranging = true }
        #endif
    }

    /// A desk clear, said with Undo, which puts the cards back.
    private func clear(_ what: String, _ text: String) {
        let changeId = todos.submit([TodoOp(fields: ["op": .string("desk.clear"), "what": .string(what)])])
        TodoUndoToast.show(text, changeId: changeId, store: todos, toasts: toasts)
    }

    /// New section, Arrange and the two clears: the desk's less used actions.
    private var actionsMenu: some View {
        Menu {
            Button("New section", systemImage: "plus") { naming = (nil, "") }
            Button("Arrange", systemImage: "arrow.up.arrow.down") { withAnimation(.snappy) { arranging = true } }
                .disabled(shown.count < 2 || arranging)
            Button("Clear done", systemImage: "checkmark.circle") {
                clear("done", "Cleared the done todos off the desk")
            }
            .disabled(todos.deskItems.isEmpty)
            Button("Clear all", systemImage: "xmark.circle", role: .destructive) {
                clear("all", "Cleared the desk")
            }
            .disabled(todos.deskItems.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 36, height: 32)
        }
        .accessibilityLabel("Desk actions")
    }

    private var deskList: some View {
        List {
            ForEach(deskRows) { row in
                switch row {
                case .item(let item): deskRow(item)
                case .addHere(let section): addHere(section)
                }
            }
            .onMove { from, destination in
                // Arranging shows the cards and sections alone, so the indexes are the desk's own.
                guard arranging, let first = from.first,
                    let op = TodoDeskArrange.onMove(shown, from: first, to: destination)
                else { return }
                todos.submit([op])
            }
            if shown.isEmpty, mode != .desk {
                Text("Nothing on the desk. Swipe a todo right to put it here.")
                    .font(.footnote)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .listRowBackground(Color.clear)
            }
            if mode == .desk {
                // Room to scroll the last row clear of the page's round add button.
                Color.clear.frame(height: 76)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 36)
        .environment(\.editMode, .constant(arranging ? .active : .inactive))
    }

    /// A row of the desk's list: a card or a section's heading, or the line that adds into the
    /// section above it.
    private enum DeskRow: Identifiable {
        case item(TodoDeskItem)
        case addHere(TodoAddDeskSection)

        var id: String {
            switch self {
            case .item(let item): TodosOverlay.deskKey(item)
            case .addHere(let section): "add:\(section.dividerId ?? "top")"
            }
        }
    }

    /// The desk's cards and sections; with the desk alone on screen and not being arranged,
    /// each section, the unnamed top one included, ends in its "Add here".
    private var deskRows: [DeskRow] {
        guard mode == .desk, !arranging else { return shown.map(DeskRow.item) }
        var rows: [DeskRow] = []
        for section in TodoDeskSections.sections(shown) {
            if let divider = section.divider { rows.append(.item(divider)) }
            rows.append(contentsOf: section.cards.map(DeskRow.item))
            rows.append(
                .addHere(
                    TodoAddDeskSection(dividerId: section.divider?.id, title: section.divider?.title ?? "Desk")))
        }
        return rows
    }

    private func addHere(_ section: TodoAddDeskSection) -> some View {
        Button {
            onAddHere(section)
        } label: {
            Label("Add here", systemImage: "plus")
                .font(.subheadline)
                .foregroundStyle(PaiPalette.primary500)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .moveDisabled(true)
        .accessibilityLabel("Add a todo to \(section.title)")
    }

    @ViewBuilder private func deskRow(_ item: TodoDeskItem) -> some View {
        if item.kind == .divider {
            Text((item.title ?? "").uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .padding(.top, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { naming = (item.id, item.title ?? "") }
                    Button("Remove title only", systemImage: "text.badge.minus") {
                        TodoUndoToast.show(
                            "Section title removed",
                            changeId: todos.submit([TodoFieldOps.removeSectionTitle(item.id)]), store: todos,
                            toasts: toasts)
                    }
                    Button("Clear section", systemImage: "xmark.circle", role: .destructive) {
                        let ops = TodoFieldOps.clearSection(item.id, in: shown)
                        guard !ops.isEmpty else { return }
                        TodoUndoToast.show(
                            "Section cleared", changeId: todos.submit(ops), store: todos, toasts: toasts)
                    }
                }
        } else if let todo = todos.todos[item.todoId ?? ""] {
            TodoRowView(model: rowModel(todo), onTick: { onTick(todo.id) }, onOpen: { onOpen(todo.id) })
                // Inside the card drawn behind the row, which is narrower than the row itself.
                .padding(.trailing, 14)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12).fill(PaiPalette.Semantic.panelBackground)
                        .padding(.vertical, 3).padding(.horizontal, 10)
                )
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    Button {
                        todos.setOnDesk(todoId: todo.id, false)
                    } label: {
                        Label("Off the desk", systemImage: "pin.slash")
                    }
                    .tint(PaiPalette.surface500)
                }
        }
    }

    private var foldedList: some View {
        Button {
            withAnimation(.snappy) { mode = .split }
        } label: {
            // The chevron sits beside the title and the whole line takes the tap: the page's
            // round add button covers the line's right end.
            HStack(spacing: 6) {
                Image(systemName: "chevron.up").font(.caption)
                Text(listTitle).font(.subheadline.weight(.semibold))
                if let listCount {
                    Text("\(listCount)").monospacedDigit().foregroundStyle(PaiPalette.Semantic.textFaint)
                }
                Spacer()
            }
            .foregroundStyle(PaiPalette.Semantic.textSecondary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
