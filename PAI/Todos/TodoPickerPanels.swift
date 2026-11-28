import PAIKit
import SwiftUI

/// One field's picker: what the add sheet shows in the keyboard's place and a todo's screen
/// raises from the bottom. A heading with Done, then the choices; a step further in (a time, the
/// nudges, a repeat) replaces the choices and leads back with the arrow.
struct TodoPickerPanel: View {
    let picker: TodoPicker
    let editing: TodoFieldEditing
    /// The step the panel opens on, for a screenshot of it.
    var startsAt: Step?
    let onDone: () -> Void

    enum Step: String {
        case time, nudge, repeats
    }

    @State private var step: Step?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if step != nil {
                    Button {
                        step = nil
                    } label: {
                        Image(systemName: "chevron.left").font(.footnote.weight(.semibold))
                    }
                    .accessibilityLabel("Back to \(picker.title)")
                }
                Text(heading.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Spacer()
                Button("Done", action: onDone).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            ScrollView {
                content
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .task { if step == nil { step = startsAt } }
        .fixtureFact("todosPicker", step?.rawValue ?? picker.rawValue)
    }

    private var heading: String {
        switch step {
        case .time: "Time"
        case .nudge: "Nudge me"
        case .repeats: "Repeat"
        case nil: picker.title
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .time: TodoTimeChoices(editing: editing) { step = nil }
        case .nudge: TodoNudgeChoices(editing: editing)
        case .repeats: TodoRepeatChoices(rule: editing.values.repeatRule, set: editing.setRepeat)
        case nil:
            switch picker {
            case .when: when
            case .deadline: TodoDeadlineChoices(editing: editing)
            case .tags: TodoTagChoices(editing: editing)
            case .horizon: TodoHorizonChoices(editing: editing, onDone: onDone)
            case .more: TodoMoreChoices(editing: editing)
            }
        }
    }

    private var when: some View {
        VStack(spacing: 8) {
            TodoDayChoices(picked: editing.values.when?.date, today: editing.today) { date in
                editing.setWhen(TodoWhen(date: date, time: editing.values.when?.time))
            }
            TodoPanelRow(
                systemImage: "clock", title: "Time",
                value: editing.values.when?.time.map { String($0.prefix(5)) } ?? "None",
                disabled: editing.values.when == nil
            ) { step = .time }
            TodoPanelRow(systemImage: "bell", title: "Nudge", value: nudgeLine) { step = .nudge }
            TodoPanelRow(
                systemImage: "repeat", title: "Repeat",
                value: editing.values.repeatRule.map(TodoWords.repeatRule) ?? "Never"
            ) { step = .repeats }
            Toggle(
                "Someday", isOn: Binding(get: { editing.values.someday }, set: { editing.setSomeday($0) })
            )
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            if editing.values.when != nil {
                Button {
                    editing.setWhen(nil)
                } label: {
                    Label("No date", systemImage: "xmark").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
                .foregroundStyle(PaiPalette.Semantic.errorText)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            }
        }
    }

    private var nudgeLine: String {
        let nudges = editing.values.nudges
        if nudges.isEmpty { return "None" }
        return nudges.count == 1 ? TodoWords.nudgeShort(nudges[0]) : "\(nudges.count) nudges"
    }
}

/// A row of a panel that leads one step in: what it is, its value, and a chevron.
struct TodoPanelRow: View {
    let systemImage: String
    let title: String
    let value: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 22).foregroundStyle(PaiPalette.Semantic.textMuted)
                Text(title).foregroundStyle(PaiPalette.Semantic.textStrong)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(PaiPalette.Semantic.textMuted).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// A choice of a panel as one wide button: its words, a quiet note, and a tick when chosen.
struct TodoPanelChoice: View {
    let title: String
    var note: String?
    let chosen: Bool
    var leading: AnyView?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let leading { leading }
                if chosen, leading == nil { Image(systemName: "checkmark").font(.footnote.weight(.bold)) }
                Text(title).foregroundStyle(PaiPalette.Semantic.textStrong)
                Spacer(minLength: 8)
                if let note { Text(note).font(.footnote).foregroundStyle(PaiPalette.Semantic.textMuted) }
            }
            .font(.subheadline.weight(chosen ? .semibold : .regular))
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 10).fill(PaiPalette.Semantic.raisedSurface))
            .overlay {
                if chosen { RoundedRectangle(cornerRadius: 10).strokeBorder(PaiPalette.primary500, lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A day: the quick choices in one row, three weeks from this Monday, and any other day.
struct TodoDayChoices: View {
    let picked: String?
    let today: String
    let onPick: (String) -> Void

    @State private var other = Date()

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let initials = ["M", "T", "W", "T", "F", "S", "S"]

    /// Three weeks of days, from the Monday of this week.
    private var days: [String] {
        let monday = TodoWords.addDays(today, 1 - TodoWords.weekday(today))
        return (0..<21).map { TodoWords.addDays(monday, $0) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(TodoWords.quickDays(today), id: \.date) { quick in
                    Button {
                        onPick(quick.date)
                    } label: {
                        VStack(spacing: 1) {
                            Text(quick.label).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(Self.weekdays[TodoWords.weekday(quick.date) - 1])
                                .font(.caption2)
                                .opacity(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .foregroundStyle(picked == quick.date ? Color.white : PaiPalette.Semantic.textStrong)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(picked == quick.date ? PaiPalette.primary500 : PaiPalette.Semantic.raisedSurface))
                    }
                    .buttonStyle(.plain)
                }
            }
            LazyVGrid(columns: Self.columns, spacing: 2) {
                ForEach(Self.initials.indices, id: \.self) { index in
                    Text(Self.initials[index])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                }
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
            DatePicker("Another day", selection: $other, displayedComponents: .date)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .onChange(of: other) { _, date in onPick(TodoDayPickerScreen.iso(date)) }
        }
    }

    private func dayColor(_ day: String, picked: Bool, past: Bool) -> Color {
        if picked { return .white }
        if day == today { return PaiPalette.primary500 }
        return past ? PaiPalette.Semantic.textFaint : PaiPalette.Semantic.textStrong
    }

    private func dayCell(_ day: String) -> some View {
        let past = TodoDates.dayDiff(today, day) < 0
        let isPicked = day == picked
        let number = Int(day.suffix(2)) ?? 0
        return Button {
            onPick(day)
        } label: {
            Text("\(number)")
                .font(.subheadline.weight(day == today || isPicked ? .bold : .regular))
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 30)
                .foregroundStyle(dayColor(day, picked: isPicked, past: past))
                .background(Circle().fill(isPicked ? PaiPalette.primary500 : Color.clear).frame(width: 30, height: 30))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(past)
        .accessibilityLabel(TodoWords.dayHeading(day, today: today).label)
    }
}

/// The time of the day a todo is planned for.
struct TodoTimeChoices: View {
    let editing: TodoFieldEditing
    let onPicked: () -> Void

    @State private var other = TodoClock.date("09:00")

    private static let times = ["09:00", "12:00", "17:00", "20:00"]

    private var current: String? { editing.values.when?.time.map { String($0.prefix(5)) } }

    private func set(_ time: String?) {
        guard let date = editing.values.when?.date else { return }
        editing.setWhen(TodoWhen(date: date, time: time))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Self.times, id: \.self) { time in
                    Button {
                        set(time)
                        onPicked()
                    } label: {
                        Text(time)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .foregroundStyle(current == time ? Color.white : PaiPalette.Semantic.textStrong)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(current == time ? PaiPalette.primary500 : PaiPalette.Semantic.raisedSurface))
                    }
                    .buttonStyle(.plain)
                }
            }
            DatePicker("Another time", selection: $other, displayedComponents: .hourAndMinute)
                .environment(\.locale, ClockTime.pickerLocale)
                .environment(\.timeZone, TodoClock.zone)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .onChange(of: other) { _, date in set(TodoClock.text(date)) }
            if current != nil {
                Button {
                    set(nil)
                    onPicked()
                } label: {
                    Label("No time", systemImage: "xmark").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            }
            Text("A time places the todo on its day; only a nudge tells you.")
                .font(.footnote)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
        }
    }
}

/// What tells the person about a todo: its nudges with what became of each, the usual ones as a
/// tap, and any other count of days at any time.
struct TodoNudgeChoices: View {
    let editing: TodoFieldEditing

    @Environment(AppEnvironment.self) private var environment
    @State private var days = 1
    @State private var time = TodoClock.date("17:00")
    @State private var custom = false

    private struct Usual: Identifiable {
        let id: String
        let title: String
        let note: String
        let choice: TodoFieldOps.NudgeChoice
        let matches: (TodoNudge) -> Bool
    }

    private var basis: String { editing.values.when == nil ? "deadline" : "when" }

    private var hasDay: Bool { editing.values.when != nil || editing.values.deadline != nil }

    private var usual: [Usual] {
        var out: [Usual] = []
        if editing.values.when?.time != nil {
            for offset in TodoWords.nudgeOffsets where offset.minutes < 1440 {
                out.append(
                    Usual(
                        id: "m\(offset.minutes)", title: offset.label, note: "",
                        choice: .before(basis: "when", minutes: offset.minutes),
                        matches: { $0.kind != "at" && $0.days == nil && ($0.offsetMinutes ?? 0) == offset.minutes }))
            }
        }
        let basis = self.basis
        for (count, at, title) in [
            (0, "09:00", "On the day"), (1, "18:00", "1 day before"), (2, "18:00", "2 days before"),
        ] {
            out.append(
                Usual(
                    id: "d\(count)", title: title, note: at, choice: .days(basis: basis, days: count, time: at),
                    matches: { $0.days == count && $0.time.map { String($0.prefix(5)) } == at }))
        }
        return out
    }

    /// The nudges none of the usual choices stands for, listed by their own words.
    private var others: [TodoNudge] {
        editing.values.nudges.filter { nudge in !usual.contains { $0.matches(nudge) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if environment.todos.me?.nudgeDevices == 0 {
                Label(
                    "No phone or browser takes your nudges right now, so a nudge would reach nobody. "
                        + "Allow notifications for PAI on one of them.",
                    systemImage: "bell.slash"
                )
                .font(.footnote)
                .foregroundStyle(PaiPalette.Semantic.warningText)
                .padding(.horizontal, 12)
            }
            if hasDay {
                ForEach(usual) { choice in
                    let held = editing.values.nudges.first(where: choice.matches)
                    TodoPanelChoice(
                        title: choice.title, note: held.map(stateLine) ?? choice.note, chosen: held != nil
                    ) {
                        if let held { editing.removeNudge(held.id) } else { editing.addNudge(choice.choice) }
                    }
                }
            } else {
                Text("Give the todo a day or a deadline to be nudged before it.")
                    .font(.footnote)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .padding(.horizontal, 12)
            }
            ForEach(others) { nudge in
                HStack(spacing: 8) {
                    TodoPanelChoice(title: TodoWords.nudge(nudge), note: stateLine(nudge), chosen: true) {
                        editing.removeNudge(nudge.id)
                    }
                    if !editing.isNew, nudge.state == .fired || nudge.state == .held || nudge.state == .missed {
                        Button("In 1 hour") { editing.snoozeNudge(nudge.id) }.font(.footnote.weight(.semibold))
                    }
                }
            }
            if hasDay {
                if custom {
                    Stepper(value: $days, in: 0...60) {
                        Text(days == 0 ? "On the day" : "\(days) day\(days == 1 ? "" : "s") before")
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                        .environment(\.locale, ClockTime.pickerLocale)
                        .environment(\.timeZone, TodoClock.zone)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                    Button("Add this nudge") {
                        editing.addNudge(.days(basis: basis, days: days, time: TodoClock.text(time)))
                        custom = false
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                } else {
                    TodoPanelChoice(title: "Another time…", chosen: false) { custom = true }
                }
            }
            if let useDefaults = editing.useDefaultNudges {
                Button("Use my default nudges", action: useDefaults)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
            }
        }
        .fixtureFact("todosDefaultNudges", String(editing.values.nudges.filter(\.isDefault).count))
    }

    /// What became of a nudge, and whether the person's defaults made it.
    private func stateLine(_ nudge: TodoNudge) -> String {
        guard !editing.isNew else { return "" }
        let state = TodoWords.nudgeState(nudge.state, fireAt: nudge.fireAt, delivered: nudge.delivered).label
        return nudge.isDefault ? "\(state) · default" : state
    }
}

/// How often a todo comes round again.
struct TodoRepeatChoices: View {
    let rule: [String: PaiJSONValue]?
    let set: ([String: PaiJSONValue]?) -> Void

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Repeats", isOn: Binding(get: { rule != nil }, set: { set($0 ? TodoFieldOps.defaultRepeat : nil) }))
            if let rule {
                Text(TodoWords.repeatRule(rule)).font(.subheadline.weight(.semibold))
                Picker("Counted from", selection: text(rule, "mode", "after_done")) {
                    Text("The day it is done").tag("after_done")
                    Text("The schedule").tag("schedule")
                }
                .pickerStyle(.segmented)
                Stepper("Every \(every(rule))", value: everyBinding(rule), in: 1...99)
                Picker(
                    "Unit", selection: Binding(get: { unit(rule) }, set: { set(TodoFieldOps.withUnit(rule, $0)) })
                ) {
                    Text("Day").tag("day")
                    Text("Week").tag("week")
                    Text("Month").tag("month")
                    Text("Year").tag("year")
                }
                .pickerStyle(.segmented)
                if unit(rule) == "week", rule["mode"] == .string("schedule") {
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { day in
                            let on = TodoFieldOps.weekdays(rule).contains(day)
                            Button(Self.weekdays[day - 1]) { set(TodoFieldOps.toggleWeekday(rule, day)) }
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .foregroundStyle(on ? Color.white : PaiPalette.Semantic.textStrong)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(on ? PaiPalette.primary500 : PaiPalette.Semantic.raisedSurface)
                                )
                                .buttonStyle(.plain)
                        }
                    }
                }
                Toggle(
                    "Skip a missed day",
                    isOn: Binding(
                        get: { rule["skip_missed"] == .bool(true) },
                        set: {
                            var next = rule
                            next["skip_missed"] = .bool($0)
                            set(next)
                        }))
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
    }

    private func unit(_ rule: [String: PaiJSONValue]) -> String {
        if case .string(let value) = rule["unit"] { return value }
        return "day"
    }

    private func every(_ rule: [String: PaiJSONValue]) -> Int {
        if case .number(let value) = rule["every"] { return NSDecimalNumber(decimal: value).intValue }
        return 1
    }

    private func everyBinding(_ rule: [String: PaiJSONValue]) -> Binding<Int> {
        Binding(
            get: { every(rule) },
            set: {
                var next = rule
                next["every"] = .number(Decimal(max(1, $0)))
                set(next)
            })
    }

    private func text(_ rule: [String: PaiJSONValue], _ key: String, _ fallback: String) -> Binding<String> {
        Binding(
            get: {
                if case .string(let value) = rule[key] { return value }
                return fallback
            },
            set: {
                var next = rule
                next[key] = .string($0)
                set(next)
            })
    }
}

/// The day a todo is owed, and how long before it shows in Today.
struct TodoDeadlineChoices: View {
    let editing: TodoFieldEditing

    @Environment(AppEnvironment.self) private var environment

    private static let leads: [(days: Int?, label: String)] = [
        (nil, "Usual"), (0, "On the day"), (1, "1 day"), (3, "3 days"), (7, "1 week"), (14, "2 weeks"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TodoDayChoices(picked: editing.values.deadline?.date, today: editing.today) { date in
                editing.setDeadline(TodoDeadline(date: date, leadDays: editing.values.deadline?.leadDays))
            }
            if let deadline = editing.values.deadline {
                Text("SHOWS IN TODAY THIS LONG BEFORE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                TodoFlowLayout(spacing: 6) {
                    ForEach(Self.leads.indices, id: \.self) { index in
                        let lead = Self.leads[index]
                        let on = deadline.leadDays == lead.days
                        Button(leadLabel(lead)) {
                            editing.setDeadline(TodoDeadline(date: deadline.date, leadDays: lead.days))
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .foregroundStyle(on ? Color.white : PaiPalette.Semantic.textStrong)
                        .background(
                            Capsule().fill(on ? PaiPalette.primary500 : PaiPalette.Semantic.raisedSurface)
                        )
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                Button {
                    editing.setDeadline(nil)
                } label: {
                    Label("No deadline", systemImage: "xmark").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
                .foregroundStyle(PaiPalette.Semantic.errorText)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            }
        }
    }

    private func leadLabel(_ lead: (days: Int?, label: String)) -> String {
        guard lead.days == nil else { return lead.label }
        let usual = environment.todos.me?.prefs?.deadlineLeadDays
        return usual.map { "Usual (\($0) d)" } ?? "Usual"
    }
}

/// A todo's tags: the known ones, the most used first, each switched on and off by a tap, and a
/// new one by name.
struct TodoTagChoices: View {
    let editing: TodoFieldEditing

    @Environment(AppEnvironment.self) private var environment
    @State private var newTag = ""

    /// The tags of the todo's list, or every tag while it has none yet; its own tags among them.
    private var known: [String] {
        let all = environment.todos.me?.tags ?? []
        let own = all.filter { editing.values.listId == nil || $0.listId == editing.values.listId }
        var counts: [String: (name: String, count: Int)] = [:]
        for tag in own {
            let key = tag.name.lowercased()
            counts[key] = (counts[key]?.name ?? tag.name, (counts[key]?.count ?? 0) + tag.openCount)
        }
        for name in editing.values.tags where counts[name.lowercased()] == nil { counts[name.lowercased()] = (name, 0) }
        return counts.values.sorted { ($0.count, $1.name.lowercased()) > ($1.count, $0.name.lowercased()) }.map(\.name)
    }

    private func isOn(_ name: String) -> Bool {
        editing.values.tags.contains { $0.lowercased() == name.lowercased() }
    }

    private func color(_ name: String) -> TodoColor {
        TodoIdentity.tagColor(name, chosen: TodoIdentity.chosenTagColors(environment.todos.me?.tags ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(PaiPalette.Semantic.textMuted)
                TextField("New tag", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addNew)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(PaiPalette.Semantic.raisedSurface))
            TodoFlowLayout(spacing: 8) {
                ForEach(known, id: \.self) { name in
                    let on = isOn(name)
                    Button {
                        editing.setTag(name, !on)
                    } label: {
                        HStack(spacing: 4) {
                            if on { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                            Text(name).lineLimit(1)
                        }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .foregroundStyle(on ? color(name).chipText : PaiPalette.Semantic.textPrimary)
                        .background(Capsule().fill(on ? color(name).chip : PaiPalette.Semantic.raisedSurface))
                        .overlay { if on { Capsule().strokeBorder(color(name).swatch, lineWidth: 1.5) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .fixtureFact("todosPickerTags", String(known.count))
    }

    private func addNew() {
        let name = newTag.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { editing.setTag(name, true) }
        newTag = ""
    }
}

/// The four horizons as big targets; one tap picks and goes back to typing.
struct TodoHorizonChoices: View {
    let editing: TodoFieldEditing
    let onDone: () -> Void

    private static let hints: [(TodoHorizon, String)] = [
        (.now, "what you are working on"), (.week, "meant for this week"), (.soon, "in the coming weeks"),
        (.whenever, "no hurry"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.hints.indices, id: \.self) { index in
                let horizon = Self.hints[index].0
                let mark = TodoHorizonMark.of(horizon)
                TodoPanelChoice(
                    title: mark.label, note: Self.hints[index].1, chosen: editing.values.horizon == horizon,
                    leading: AnyView(TodoTickCircle(mark: mark, done: false, size: 20))
                ) {
                    editing.setHorizon(horizon)
                    onDone()
                }
            }
        }
    }
}

/// Where a todo lives and whether it is on the desk.
struct TodoMoreChoices: View {
    let editing: TodoFieldEditing

    @Environment(AppEnvironment.self) private var environment

    /// Lists this person can put a todo into: owner or editor, not locked, not archived.
    private var lists: [TodoList] {
        environment.todos.lists.filter { !$0.archived && !$0.locked && ($0.role == .owner || $0.role == .editor) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { editing.values.onDesk }, set: { editing.setDesk($0) })) {
                Label("On the desk", systemImage: "pin")
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            if editing.canMove, editing.canEdit, lists.count > 1 {
                Text("LIST")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .padding(.horizontal, 12)
                ForEach(lists) { list in
                    TodoPanelChoice(title: list.name, chosen: list.id == effectiveList) {
                        if list.id != effectiveList { editing.setList(list.id) }
                    }
                }
            }
        }
    }

    /// A new todo nobody gave a list goes to the person's own. Existing todos in different
    /// lists have none in common, and no list is marked.
    private var effectiveList: String? {
        editing.values.listId ?? (editing.isNew ? environment.todos.me?.prefs?.defaultListId : nil)
    }
}
