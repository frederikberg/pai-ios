import PAIKit
import SwiftUI

/// The fields of a todo in its sheet, in the web pane's order: horizon, when (day, time, repeat
/// and nudges), deadline, tags, list, desk. A row names its value; tapping it opens its choices.
struct TodoFieldSections: View {
    let todo: Todo
    let today: String
    let canEdit: Bool
    let submit: ([TodoOp]) -> Void

    @Environment(AppEnvironment.self) private var environment

    private var store: TodosStore { environment.todos }
    private var nudges: [TodoNudge] { store.nudges(of: todo.id) }

    var body: some View {
        Section {
            horizonRow
            NavigationLink {
                TodoWhenScreen(todo: todo, today: today, canEdit: canEdit, submit: submit)
            } label: {
                fieldLabel("When", systemImage: "calendar", value: whenLine, set: whenIsSet)
            }
            NavigationLink {
                TodoDeadlineScreen(todo: todo, today: today, submit: submit)
            } label: {
                fieldLabel("Deadline", systemImage: "flag", value: deadlineLine, set: todo.deadline != nil)
            }
            .disabled(!canEdit)
            NavigationLink {
                TodoTagsScreen(todo: todo, submit: submit)
            } label: {
                fieldLabel("Tags", systemImage: "number", value: tagsLine, set: !todo.tags.isEmpty)
            }
            .disabled(!canEdit)
            listRow
            deskRow
        }
    }

    private func fieldLabel(_ name: String, systemImage: String, value: String, set: Bool) -> some View {
        HStack {
            Label(name, systemImage: systemImage).foregroundStyle(PaiPalette.Semantic.textMuted)
            Spacer()
            Text(value)
                .foregroundStyle(set ? PaiPalette.Semantic.textStrong : PaiPalette.Semantic.textFaint)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private var horizonRow: some View {
        Menu {
            ForEach([TodoHorizon.now, .week, .soon, .whenever], id: \.rawValue) { horizon in
                Button(TodoHorizonMark.of(horizon).label) {
                    if horizon != todo.horizon { submit([TodoFieldOps.horizon(todo.id, horizon)]) }
                }
            }
        } label: {
            HStack {
                Label("Horizon", systemImage: "circle.dashed").foregroundStyle(PaiPalette.Semantic.textMuted)
                Spacer()
                TodoTickCircle(mark: TodoHorizonMark.of(todo.horizon), done: false, size: 14)
                Text(TodoHorizonMark.of(todo.horizon).label).foregroundStyle(PaiPalette.Semantic.textStrong)
            }
        }
        .disabled(!canEdit)
    }

    private var whenIsSet: Bool { todo.when != nil || todo.someday || todo.repeat != nil || !nudges.isEmpty }

    /// The day and time, how it repeats, and what notifies: the web's `whenLine`.
    private var whenLine: String {
        var parts: [String] = []
        if let when = todo.when {
            parts.append(TodoDates.relativeDay(when.date, today: today) + (when.time.map { " \($0.prefix(5))" } ?? ""))
        } else if todo.someday {
            parts.append("Someday")
        }
        if let rule = todo.repeat {
            var json = TodoFieldOps.repeatJSON(rule)
            json["until"] = nil
            let words = TodoWords.repeatRule(json)
            parts.append(words.prefix(1).lowercased() + words.dropFirst())
        }
        if nudges.count == 1 {
            parts.append("nudge \(TodoWords.nudgeShort(nudges[0]))")
        } else if nudges.count > 1 {
            parts.append("\(nudges.count) nudges")
        }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    private var deadlineLine: String {
        todo.deadline.map { "Due \(TodoDates.relativeDay($0.date, today: today))" } ?? "None"
    }

    private var tagsLine: String {
        let tags = todo.tags.isEmpty ? todo.inheritedTags : todo.tags
        guard !tags.isEmpty else { return "None" }
        return tags.prefix(3).map(TodoIdentity.tagLeaf).joined(separator: " · ")
            + (tags.count > 3 ? " +\(tags.count - 3)" : "")
    }

    /// Lists this person can move a todo into: owner or editor, not locked, not archived.
    private var movableLists: [TodoList] {
        store.lists.filter { !$0.archived && !$0.locked && ($0.role == .owner || $0.role == .editor) }
    }

    private var listRow: some View {
        Menu {
            ForEach(movableLists) { list in
                Button(list.name) {
                    if list.id != todo.listId { submit([TodoFieldOps.move(todo.id, toList: list.id)]) }
                }
            }
        } label: {
            HStack {
                Label("List", systemImage: "tray.full").foregroundStyle(PaiPalette.Semantic.textMuted)
                Spacer()
                Text(store.lists.first { $0.id == todo.listId }?.name ?? "—").foregroundStyle(
                    PaiPalette.Semantic.textStrong)
            }
        }
        .disabled(!canEdit || todo.parentId != nil || movableLists.count < 2)
    }

    /// The desk is the person's own: open to them whatever the list allows.
    private var deskRow: some View {
        Menu {
            if todo.onDesk {
                Button("Move to the top") { store.submit([TodoFieldOps.deskMove(todo.id, position: .first)]) }
                Button("Move to the bottom") { store.submit([TodoFieldOps.deskMove(todo.id, position: .last)]) }
                Button("Take off the desk", role: .destructive) { store.setOnDesk(todoId: todo.id, false) }
            } else {
                Button("Put on top") { store.submit([.deskAdd(todo: todo.id, position: .first)]) }
                Button("Put at the bottom") { store.submit([.deskAdd(todo: todo.id, position: .last)]) }
            }
        } label: {
            HStack {
                Label("Desk", systemImage: "pin").foregroundStyle(PaiPalette.Semantic.textMuted)
                Spacer()
                Text(todo.onDesk ? "On the desk" : "Not on the desk")
                    .foregroundStyle(todo.onDesk ? PaiPalette.primary500 : PaiPalette.Semantic.textFaint)
            }
        }
    }
}

/// A day: the quick choices, then any day of a month.
struct TodoDayPickerScreen: View {
    let title: String
    let today: String
    var maxDate: String?
    /// Nil means "none".
    var clearLabel: String?
    let onPick: (String?) -> Void

    @State private var picked = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TodoWords.quickDays(today).filter { maxDate == nil || $0.date <= maxDate! }, id: \.date) {
                        quick in
                        Button {
                            onPick(quick.date)
                        } label: {
                            HStack {
                                Text(quick.label)
                                Spacer()
                                Text(TodoWords.dayHeading(quick.date, today: today).label)
                                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                            }
                        }
                    }
                    if let clearLabel {
                        Button(clearLabel, role: .destructive) { onPick(nil) }
                    }
                }
                Section {
                    DatePicker("Day", selection: $picked, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                    Button("Choose this day") { onPick(Self.iso(picked)) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    static func iso(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// When it happens, how often, and whether it tells you, the web's When popover: a day (quick
/// choices or the month), its time, Someday, the repeat and the nudges counted from that time.
struct TodoWhenScreen: View {
    let todo: Todo
    let today: String
    let canEdit: Bool
    let submit: ([TodoOp]) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var picked = Date()

    private static let times = ["09:00", "12:00", "17:00", "20:00"]
    private var store: TodosStore { environment.todos }
    private var current: Todo { store.todos[todo.id] ?? todo }

    var body: some View {
        List {
            if canEdit { daySection }
            if canEdit, current.when != nil { timeSection }
            if canEdit { repeatSection }
            nudgeSection
        }
        .fixtureFact("todosDefaultNudges", String(store.nudges(of: todo.id).filter(\.isDefault).count))
        .navigationTitle("When")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var daySection: some View {
        Section("Day") {
            ForEach(TodoWords.quickDays(today), id: \.date) { quick in
                Button {
                    submit([TodoFieldOps.when(todo.id, date: quick.date, time: current.when?.time)])
                } label: {
                    HStack {
                        Text(quick.label)
                        Spacer()
                        if current.when?.date == quick.date { Image(systemName: "checkmark") }
                    }
                }
            }
            DatePicker("Another day", selection: $picked, displayedComponents: .date)
                .onChange(of: picked) { _, date in
                    submit([TodoFieldOps.when(todo.id, date: TodoDayPickerScreen.iso(date), time: current.when?.time)])
                }
            Toggle(
                "Someday", isOn: Binding(get: { current.someday }, set: { submit([TodoFieldOps.someday(todo.id, $0)]) })
            )
            if current.when != nil {
                Button("No day", role: .destructive) { submit([TodoFieldOps.when(todo.id, date: nil)]) }
            }
        }
    }

    private var timeSection: some View {
        Section("Time") {
            ForEach(Self.times, id: \.self) { time in
                Button {
                    if let date = current.when?.date { submit([TodoFieldOps.when(todo.id, date: date, time: time)]) }
                } label: {
                    HStack {
                        Text(time).monospacedDigit()
                        Spacer()
                        if current.when?.time?.prefix(5) == Substring(time) { Image(systemName: "checkmark") }
                    }
                }
            }
            if current.when?.time != nil {
                Button("No time") {
                    if let date = current.when?.date { submit([TodoFieldOps.when(todo.id, date: date, time: nil)]) }
                }
            }
            Text("A time places the todo on its day; only a nudge tells you.")
                .font(.footnote)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
    }

    private var repeatSection: some View {
        Section("Repeat") {
            NavigationLink {
                TodoRepeatScreen(todo: current, submit: submit)
            } label: {
                HStack {
                    Text("Repeat")
                    Spacer()
                    Text(current.repeat.map { TodoWords.repeatRule(TodoFieldOps.repeatJSON($0)) } ?? "Never")
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    private var nudgeSection: some View {
        Section {
            ForEach(store.nudges(of: todo.id)) { nudge in
                let state = TodoWords.nudgeState(nudge.state, fireAt: nudge.fireAt)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(TodoWords.nudge(nudge))
                        if nudge.isDefault { TodoDefaultMark() }
                    }
                    Text(state.label).font(.caption).foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { store.submit([TodoFieldOps.nudgeRemove(nudge.id)]) }
                    if nudge.state == .fired || nudge.state == .held || nudge.state == .missed {
                        Button("In 1 hour") { store.submit([TodoFieldOps.nudgeSnooze(nudge.id, minutes: 60)]) }
                    }
                }
            }
            if current.when?.time != nil {
                Menu("Add a nudge") {
                    ForEach(TodoWords.nudgeOffsets.indices, id: \.self) { index in
                        let offset = TodoWords.nudgeOffsets[index]
                        Button(offset.label) {
                            store.submit([
                                TodoFieldOps.nudgeSet(
                                    todo.id, .before(basis: "when", minutes: offset.minutes), id: TodosStore.uuidv7())
                            ])
                        }
                    }
                }
            }
            if current.when != nil || current.deadline != nil {
                NavigationLink("Days before, at a time") {
                    TodoNudgeDaysScreen(todo: current) { choice in
                        store.submit([TodoFieldOps.nudgeSet(todo.id, choice, id: TodosStore.uuidv7())])
                    }
                }
            } else {
                Text("Give the todo a day or a deadline to be nudged before it.")
                    .font(.footnote)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if TodoFieldOps.offersDefaults(current, prefs: store.me?.prefs) {
                Button("Use my default nudges") { store.submit([TodoFieldOps.nudgeDefaults(todo.id)]) }
            }
        } header: {
            Text("Nudges")
        }
    }
}

/// The quiet mark on a nudge the person's default nudges made.
struct TodoDefaultMark: View {
    var body: some View {
        Text("default")
            .font(.caption2)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(PaiPalette.Semantic.raisedSurface))
            .accessibilityLabel("Made by your default nudges")
    }
}

/// A nudge whole days before the day or the deadline, at a time of day: it rings at that
/// wall-clock time whatever the todo's own time is.
struct TodoNudgeDaysScreen: View {
    let todo: Todo
    let add: (TodoFieldOps.NudgeChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days = 1
    @State private var time = TodoNudgeDaysScreen.clock("17:00")
    @State private var basis = "when"

    var body: some View {
        Form {
            Stepper(value: $days, in: 0...60) {
                Text(days == 0 ? "On the day" : "\(days) day\(days == 1 ? "" : "s") before")
            }
            DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                .environment(\.locale, ClockTime.pickerLocale)
                .environment(\.timeZone, Self.calendar.timeZone)
            if todo.when != nil, todo.deadline != nil {
                Picker("Counted from", selection: $basis) {
                    Text("The day").tag("when")
                    Text("The deadline").tag("deadline")
                }
            }
            Section {
                Button("Add nudge") {
                    add(.days(basis: basis, days: days, time: Self.hhmm(time)))
                    dismiss()
                }
            } footer: {
                Text(preview).foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .navigationTitle("Days before")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if todo.when == nil { basis = "deadline" } }
    }

    private var preview: String {
        TodoWords.nudge(kind: "before", date: nil, time: Self.hhmm(time), basis: basis, offsetMinutes: nil, days: days)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func clock(_ text: String) -> Date {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: parts[0], minute: parts[1]))
            ?? Date()
    }

    static func hhmm(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// How often a todo comes round again.
struct TodoRepeatScreen: View {
    let todo: Todo
    let submit: ([TodoOp]) -> Void

    @Environment(AppEnvironment.self) private var environment

    private var rule: [String: PaiJSONValue]? {
        (environment.todos.todos[todo.id] ?? todo).repeat.map(TodoFieldOps.repeatJSON)
    }

    private func set(_ next: [String: PaiJSONValue]?) { submit([TodoFieldOps.repeat(todo.id, next)]) }

    var body: some View {
        List {
            Section {
                Toggle(
                    "Repeats", isOn: Binding(get: { rule != nil }, set: { set($0 ? TodoFieldOps.defaultRepeat : nil) }))
            }
            if let rule {
                Section {
                    Text(TodoWords.repeatRule(rule)).font(.headline)
                    Picker(
                        "Counted from",
                        selection: Binding(
                            get: { mode(rule) },
                            set: {
                                var next = rule; next["mode"] = .string($0); set(next)
                            })
                    ) {
                        Text("The day it is done").tag("after_done")
                        Text("The schedule").tag("schedule")
                    }
                    Stepper(
                        "Every \(every(rule))",
                        value: Binding(
                            get: { every(rule) },
                            set: {
                                var next = rule; next["every"] = .number(Decimal(max(1, $0))); set(next)
                            }), in: 1...99)
                    Picker(
                        "Unit", selection: Binding(get: { unit(rule) }, set: { set(TodoFieldOps.withUnit(rule, $0)) })
                    ) {
                        Text("Day").tag("day")
                        Text("Week").tag("week")
                        Text("Month").tag("month")
                        Text("Year").tag("year")
                    }
                }
                if unit(rule) == "week" && mode(rule) == "schedule" {
                    Section("On") {
                        ForEach(1...7, id: \.self) { day in
                            Button {
                                set(TodoFieldOps.toggleWeekday(rule, day))
                            } label: {
                                HStack {
                                    Text(Self.weekdays[day - 1])
                                    Spacer()
                                    if TodoFieldOps.weekdays(rule).contains(day) { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                Section {
                    Toggle(
                        "Skip a missed day",
                        isOn: Binding(
                            get: { rule["skip_missed"] == .bool(true) },
                            set: {
                                var next = rule; next["skip_missed"] = .bool($0); set(next)
                            }))
                }
            }
        }
        .navigationTitle("Repeat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private func mode(_ rule: [String: PaiJSONValue]) -> String {
        if case .string(let value) = rule["mode"] { return value }
        return "after_done"
    }

    private func unit(_ rule: [String: PaiJSONValue]) -> String {
        if case .string(let value) = rule["unit"] { return value }
        return "day"
    }

    private func every(_ rule: [String: PaiJSONValue]) -> Int {
        if case .number(let value) = rule["every"] { return NSDecimalNumber(decimal: value).intValue }
        return 1
    }
}

/// The day a todo is owed, and how long before it shows in Today.
struct TodoDeadlineScreen: View {
    let todo: Todo
    let today: String
    let submit: ([TodoOp]) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var picked = Date()

    private static let leads: [(days: Int?, label: String)] = [
        (nil, "Usual"), (0, "On the day"), (1, "1 day"), (3, "3 days"), (7, "1 week"), (14, "2 weeks"),
    ]

    private var current: Todo { environment.todos.todos[todo.id] ?? todo }

    var body: some View {
        List {
            Section("Day") {
                ForEach(TodoWords.quickDays(today), id: \.date) { quick in
                    Button {
                        submit([TodoFieldOps.deadline(todo.id, date: quick.date, leadDays: current.deadline?.leadDays)])
                    } label: {
                        HStack {
                            Text(quick.label)
                            Spacer()
                            if current.deadline?.date == quick.date { Image(systemName: "checkmark") }
                        }
                    }
                }
                DatePicker("Another day", selection: $picked, displayedComponents: .date)
                    .onChange(of: picked) { _, date in
                        submit([
                            TodoFieldOps.deadline(
                                todo.id, date: TodoDayPickerScreen.iso(date), leadDays: current.deadline?.leadDays)
                        ])
                    }
                if current.deadline != nil {
                    Button("No deadline", role: .destructive) { submit([TodoFieldOps.deadline(todo.id, date: nil)]) }
                }
            }
            if let deadline = current.deadline {
                Section("Shows in Today this long before") {
                    ForEach(Self.leads.indices, id: \.self) { index in
                        let lead = Self.leads[index]
                        Button {
                            submit([TodoFieldOps.deadline(todo.id, date: deadline.date, leadDays: lead.days)])
                        } label: {
                            HStack {
                                Text(leadLabel(lead))
                                Spacer()
                                if deadline.leadDays == lead.days { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Deadline")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func leadLabel(_ lead: (days: Int?, label: String)) -> String {
        guard lead.days == nil else { return lead.label }
        let usual = environment.todos.me?.prefs?.deadlineLeadDays
        return usual.map { "Usual (\($0) d)" } ?? "Usual"
    }
}

/// A todo's tags: its list's tags to switch on and off, and a new one by name.
struct TodoTagsScreen: View {
    let todo: Todo
    let submit: ([TodoOp]) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var newTag = ""

    private var current: Todo { environment.todos.todos[todo.id] ?? todo }

    private var known: [String] {
        let names = (environment.todos.me?.tags ?? []).filter { $0.listId == current.listId }.map(\.name)
        return Array(Set(names + current.tags)).sorted { $0.lowercased() < $1.lowercased() }
    }

    private func color(_ name: String) -> TodoColor {
        TodoIdentity.tagColor(name, chosen: TodoIdentity.chosenTagColors(environment.todos.me?.tags ?? []))
    }

    var body: some View {
        List {
            Section {
                TextField("New tag", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit {
                        let name = newTag.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { submit([TodoFieldOps.tag(todo.id, add: [name])]) }
                        newTag = ""
                    }
            }
            Section {
                ForEach(known, id: \.self) { name in
                    let on = current.tags.contains { $0.lowercased() == name.lowercased() }
                    Button {
                        submit([on ? TodoFieldOps.tag(todo.id, remove: [name]) : TodoFieldOps.tag(todo.id, add: [name])]
                        )
                    } label: {
                        HStack {
                            TodoTagChip(name: name, color: color(name), whole: true)
                            Spacer()
                            if on { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            if !current.inheritedTags.isEmpty {
                Section("From its parent") {
                    Text(current.inheritedTags.joined(separator: ", ")).foregroundStyle(PaiPalette.Semantic.textMuted)
                }
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }
}
