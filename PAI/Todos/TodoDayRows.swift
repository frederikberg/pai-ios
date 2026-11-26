import PAIKit
import SwiftUI

/// Upcoming and the Logbook as day screens, the web's agenda and log layouts: a heading per day
/// with its date beside it; under it the todos planned for it, the ones due on it and the quiet
/// ghosts of repeating todos (Upcoming), or one row per completion (the Logbook, where the circle
/// reopens).
struct TodoDayRows: View {
    /// `agenda` or `log`.
    let layout: String
    let rowModel: (Todo) -> TodoRowModel
    let onTick: (String) -> Void
    let onOpen: (String) -> Void

    @Environment(AppEnvironment.self) private var environment

    private var store: TodosStore { environment.todos }

    private var rows: [TodoDayRow] {
        let today = store.personsToday
        if layout == "agenda" {
            guard let upcoming = store.upcoming else { return [] }
            return TodoDays.upcomingRows(upcoming, todos: store.todos, today: today, pending: store.queue)
        }
        guard let logbook = store.logbook else { return [] }
        return TodoDays.logbookRows(logbook.days, todos: store.logbookTodos, today: today)
    }

    private var loaded: Bool { layout == "agenda" ? store.upcoming != nil : store.logbook != nil }

    var body: some View {
        ForEach(rows) { row in
            rowView(row)
        }
        .fixtureFact("todosDayRows", String(rows.count))
        if !loaded {
            ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
        } else if rows.isEmpty {
            Text(layout == "agenda" ? "Nothing ahead." : "Nothing done yet.")
                .font(.footnote)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        if layout == "log", store.logbook?.nextCursor != nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .task { await store.loadLogbook(more: true) }
        }
        Color.clear.frame(height: 72).listRowSeparator(.hidden)
    }

    @ViewBuilder private func rowView(_ row: TodoDayRow) -> some View {
        switch row {
        case .heading(_, let label, let sub, _, let count):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.headline).foregroundStyle(PaiPalette.Semantic.textStrong)
                if let sub { Text(sub).font(.subheadline).foregroundStyle(PaiPalette.Semantic.textMuted) }
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(PaiPalette.Semantic.textFaint)
                }
            }
            .padding(.top, 10)
            .listRowSeparator(.hidden)
        case .todo(_, let id):
            if let todo = store.todos[id] {
                TodoRowView(model: rowModel(todo), onTick: { onTick(id) }, onOpen: { onOpen(id) })
            }
        case .ghost(_, let todoId, _):
            if let todo = store.todos[todoId] {
                Label(todo.title, systemImage: "repeat")
                    .font(.subheadline)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .padding(.leading, 24)
            }
        case .entry(_, let todoId, _, _, let kind, let byLabel):
            if let todo = store.logbookTodos[todoId] {
                HStack(spacing: 10) {
                    Button {
                        store.submit([.reopen(todo: todoId)])
                    } label: {
                        TodoTickCircle(mark: TodoHorizonMark.of(todo.horizon), done: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reopen")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(todo.title).foregroundStyle(PaiPalette.Semantic.textPrimary)
                        Text(Self.entryLine(kind: kind, by: byLabel))
                            .font(.caption)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(todoId) }
                }
            }
        }
    }

    private static func entryLine(kind: String, by: String) -> String {
        let what: String =
            switch kind {
            case "dropped": "Dropped"
            case "skipped": "Skipped"
            default: "Done"
            }
        return "\(what) · \(by)"
    }
}
