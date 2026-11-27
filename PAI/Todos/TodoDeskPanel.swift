import PAIKit
import SwiftUI

/// The desk above a page, in one of its three states (`TodoDeskMode`): a bar that says how much is
/// on it and what comes first; the split, the desk over the list, each with its own scroll and the
/// desk at most half the height; or the desk alone, with the list folded to one line under it.
/// Each step is one press. A todo reaches the desk by swiping its row right.
struct TodoDeskPanel<ListContent: View>: View {
    let todos: TodosStore
    @Binding var mode: TodoDeskMode
    /// The page's title and count, for the line the list folds to.
    let listTitle: String
    let listCount: Int?
    let rowModel: (Todo) -> TodoRowModel
    let onTick: (String) -> Void
    let onOpen: (String) -> Void
    @ViewBuilder let list: () -> ListContent

    /// The cards can be dragged into a new order, sections included.
    @State private var arranging = false
    /// The section being named: a new one (nil id) or one renamed.
    @State private var naming: (id: String?, title: String)?

    private var cards: [TodoDeskItem] { todos.deskItems.filter { $0.kind == .todo } }

    /// The split's share of the height for the desk: what its items need, at most about half.
    private var deskShare: CGFloat { min(0.48, 0.12 + CGFloat(todos.deskItems.count) * 0.075) }

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
            withAnimation(.snappy) { mode = .split }
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
                Button {
                    withAnimation(.snappy) { mode = .bar }
                } label: {
                    Image(systemName: "chevron.up").frame(width: 36, height: 32)
                }
                .accessibilityLabel("Fold the desk")
            }
            .font(.subheadline)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
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

    /// New section, Arrange and the two clears: the desk's less used actions.
    private var actionsMenu: some View {
        Menu {
            Button("New section", systemImage: "plus") { naming = (nil, "") }
            Button("Arrange", systemImage: "arrow.up.arrow.down") { withAnimation(.snappy) { arranging = true } }
                .disabled(todos.deskItems.count < 2 || arranging)
            Button("Clear done", systemImage: "checkmark.circle") {
                todos.submit([TodoOp(fields: ["op": .string("desk.clear"), "what": .string("done")])])
            }
            .disabled(todos.deskItems.isEmpty)
            Button("Clear all", systemImage: "xmark.circle", role: .destructive) {
                todos.submit([TodoOp(fields: ["op": .string("desk.clear"), "what": .string("all")])])
            }
            .disabled(todos.deskItems.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 36, height: 32)
        }
        .accessibilityLabel("Desk actions")
    }

    private var deskList: some View {
        List {
            ForEach(todos.deskItems) { item in
                deskRow(item)
            }
            .onMove { from, destination in
                guard let first = from.first,
                    let op = TodoDeskArrange.onMove(todos.deskItems, from: first, to: destination)
                else { return }
                todos.submit([op])
            }
            if todos.deskItems.isEmpty {
                Text("Nothing on the desk. Swipe a todo right to put it here.")
                    .font(.footnote)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 36)
        .environment(\.editMode, .constant(arranging ? .active : .inactive))
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
                    Button("Rename") { naming = (item.id, item.title ?? "") }
                    Button("Clear section", role: .destructive) { todos.submit([TodoFieldOps.clearSection(item.id)]) }
                }
        } else if let todo = todos.todos[item.todoId ?? ""] {
            TodoRowView(model: rowModel(todo), onTick: { onTick(todo.id) }, onOpen: { onOpen(todo.id) })
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
            HStack(spacing: 6) {
                Text(listTitle).font(.subheadline.weight(.semibold))
                if let listCount {
                    Text("\(listCount)").monospacedDigit().foregroundStyle(PaiPalette.Semantic.textFaint)
                }
                Spacer()
                Image(systemName: "chevron.up").font(.caption)
            }
            .foregroundStyle(PaiPalette.Semantic.textSecondary)
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
    }
}
