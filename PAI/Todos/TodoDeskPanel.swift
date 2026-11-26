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
    @ViewBuilder let list: () -> ListContent

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
                Text("\(cards.count)").font(.subheadline).monospacedDigit().foregroundStyle(
                    PaiPalette.Semantic.textFaint)
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
                Text("Desk").font(.subheadline.weight(.semibold)).foregroundStyle(PaiPalette.Semantic.textStrong)
                Text("\(cards.count)").font(.caption).monospacedDigit().foregroundStyle(PaiPalette.Semantic.textFaint)
                Spacer()
                clearMenu
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
    }

    private var clearMenu: some View {
        Menu {
            Button("Clear done") {
                todos.submit([TodoOp(fields: ["op": .string("desk.clear"), "what": .string("done")])])
            }
            Button("Clear all", role: .destructive) {
                todos.submit([TodoOp(fields: ["op": .string("desk.clear"), "what": .string("all")])])
            }
        } label: {
            Text("Clear").padding(.horizontal, 6)
        }
        .disabled(todos.deskItems.isEmpty)
    }

    private var deskList: some View {
        List {
            ForEach(todos.deskItems) { item in
                deskRow(item)
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
    }

    @ViewBuilder private func deskRow(_ item: TodoDeskItem) -> some View {
        if item.kind == .divider {
            Text((item.title ?? "").uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .padding(.top, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if let todo = todos.todos[item.todoId ?? ""] {
            TodoRowView(model: rowModel(todo), onTick: { onTick(todo.id) })
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
