import PAIKit
import SwiftUI

/// Todos' settings on the phone, the web's Settings sections that fit a phone: General, Nudges,
/// Lists (with their people), Tags and Views. Every change is the op the web sends
/// (`TodoSettingsOps`), queued like any change; the screen shows `/me` as read after it.
struct TodoSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var fixtureSection: TodoSettingsSection?

    private var store: TodosStore { environment.todos }

    var body: some View {
        List {
            Section {
                ForEach(TodoSettingsSection.allCases) { section in
                    NavigationLink {
                        section.screen
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 7).fill(section.color.swatch))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title).foregroundStyle(PaiPalette.Semantic.textStrong)
                                Text(section.hint).font(.caption).foregroundStyle(PaiPalette.Semantic.textMuted)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                if let name = store.me?.displayName { Text("Signed in as \(name)") }
            } footer: {
                Text(
                    "Scopes, a view's layout, grouping and defaults, and the keyboard shortcuts are in Todos on the web."
                )
            }
        }
        .navigationTitle("Todos settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $fixtureSection) { $0.screen }
        .task {
            #if DEBUG
                if let name = PaiFixtureLaunch.requestedTodosSettings() {
                    fixtureSection = TodoSettingsSection(rawValue: name == "view-new" ? "views" : name)
                }
            #endif
        }
        .fixtureFact("todosSettings", "all")
    }
}

/// The sections, in the web's order.
enum TodoSettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, nudges, lists, tags, views

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .nudges: "Nudges"
        case .lists: "Lists"
        case .tags: "Tags"
        case .views: "Views"
        }
    }

    var hint: String {
        switch self {
        case .general: "Time zone, when the day starts, where new todos go"
        case .nudges: "The reminders a todo gets by itself"
        case .lists: "Where todos live, and who shares them"
        case .tags: "Colours, quiet tags, merging and deleting"
        case .views: "New views, their names, order and favourites"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .nudges: "bell"
        case .lists: "list.bullet"
        case .tags: "number"
        case .views: "star"
        }
    }

    var color: TodoColor {
        switch self {
        case .general: .slate
        case .nudges: .rose
        case .lists: .blue
        case .tags: .violet
        case .views: .amber
        }
    }

    /// The section's screen. It reports itself as the section on show: the list beneath it in the
    /// navigation stack is not drawn again when one is pushed, so its own report would stay "all".
    @MainActor var screen: some View {
        content.fixtureFact("todosSettings", rawValue)
    }

    @MainActor @ViewBuilder private var content: some View {
        switch self {
        case .general: TodoGeneralSettings()
        case .nudges: TodoNudgeSettings()
        case .lists: TodoListsSettings()
        case .tags: TodoTagsSettings()
        case .views: TodoViewsSettings()
        }
    }
}

/// Sends settings ops and says a refusal; what was applied shows once `/me` is read again.
@MainActor
enum TodoSettingsApply {
    static func send(_ ops: [TodoOp?], store: TodosStore, toasts: ToastCenter) {
        let ops = ops.compactMap { $0 }
        guard !ops.isEmpty else { return }
        Task {
            switch await store.applySettings(ops) {
            case .refused(let refusal): toasts.show(refusal.message, kind: .error)
            case .waiting: toasts.show("Saved on this iPhone. It is sent once there is a connection.", kind: .info)
            case .applied: break
            }
        }
    }
}

/// `HH:MM` and back, read and shown in UTC so the clock a person picks is the one sent.
enum TodoClock {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static var zone: TimeZone { calendar.timeZone }

    static func date(_ text: String) -> Date {
        let parts = text.prefix(5).split(separator: ":").compactMap { Int($0) }
        let hour = parts.first ?? 0
        let minute = parts.count > 1 ? parts[1] : 0
        return calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
    }

    static func text(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - General

struct TodoGeneralSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @State private var rollover = Date()

    private var store: TodosStore { environment.todos }
    private var prefs: TodoPrefs? { store.me?.prefs }

    /// Lists a new todo can go to: the person's own, or one they may change.
    private var targets: [TodoList] {
        store.lists.filter { !$0.archived && ($0.role == .owner || $0.role == .editor) }
    }

    var body: some View {
        Form {
            if let prefs {
                Section {
                    NavigationLink {
                        TodoTimeZonePicker(current: prefs.timezone) { send([TodoSettingsOps.timezone($0)]) }
                    } label: {
                        LabeledContent("Time zone", value: prefs.timezone)
                    }
                    DatePicker("The day starts at", selection: $rollover, displayedComponents: .hourAndMinute)
                        .environment(\.locale, ClockTime.pickerLocale)
                        .environment(\.timeZone, TodoClock.zone)
                        .onChange(of: rollover) { _, picked in
                            let text = TodoClock.text(picked)
                            if text != String(prefs.dayRollover.prefix(5)) {
                                send([TodoSettingsOps.dayRollover(text)])
                            }
                        }
                } footer: {
                    Text("What you finish before this belongs to the day before. Ticked todos leave the desk then.")
                }
                Section {
                    Stepper(
                        value: Binding(
                            get: { prefs.deadlineLeadDays },
                            set: { send([TodoSettingsOps.deadlineLeadDays($0)]) }),
                        in: 0...365
                    ) {
                        Text(
                            "A deadline shows \(prefs.deadlineLeadDays) day\(prefs.deadlineLeadDays == 1 ? "" : "s") ahead"
                        )
                    }
                } footer: {
                    Text("A todo with a deadline appears in Today this many days before it.")
                }
                Section {
                    Picker(
                        "New todos go to",
                        selection: Binding(
                            get: { prefs.defaultListId ?? "" },
                            set: { send([TodoSettingsOps.defaultList($0.isEmpty ? nil : $0)]) })
                    ) {
                        Text("My personal list").tag("")
                        ForEach(targets) { list in Text(list.name).tag(list.id) }
                    }
                } footer: {
                    Text(
                        "Describing a todo in your own words sends your text and the names of your lists and tags to the model that reads it."
                    )
                }
            } else {
                Text("Todos has not been read yet.").foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .task { if let prefs { rollover = TodoClock.date(prefs.dayRollover) } }
        .fixtureFact("todosSettingsZone", prefs?.timezone ?? "")
    }

    private func send(_ ops: [TodoOp?]) { TodoSettingsApply.send(ops, store: store, toasts: toasts) }
}

struct TodoTimeZonePicker: View {
    let current: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        let listed = all.contains(current) ? all : [current] + all
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? listed : listed.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        List(zones, id: \.self) { zone in
            Button {
                if zone != current { onPick(zone) }
                dismiss()
            } label: {
                HStack {
                    Text(zone.replacingOccurrences(of: "_", with: " ")).foregroundStyle(PaiPalette.Semantic.textStrong)
                    Spacer()
                    if zone == current { Image(systemName: "checkmark") }
                }
            }
        }
        .searchable(text: $query, prompt: "City or region")
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Nudges

struct TodoNudgeSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts

    private typealias Edit = TodoNudgeDefaultsEdit
    private var store: TodosStore { environment.todos }
    private var nudges: TodoDefaultNudges {
        store.me?.prefs?.defaultNudges ?? TodoDefaultNudges(timed: [], day: [], deadline: [])
    }

    var body: some View {
        Form {
            Section {
                Text(
                    "A time on a todo never notifies by itself. These are the nudges a todo gets when you give it a day or a deadline; take one off a todo to opt out for that todo. A nudge that falls in your night waits for the morning."
                )
                .font(.footnote)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            ForEach(Edit.Kind.allCases) { kind in
                let entries = Edit.entries(nudges, kind)
                Section {
                    if entries.isEmpty {
                        Text("No nudge.").foregroundStyle(PaiPalette.Semantic.textFaint)
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        NavigationLink {
                            TodoNudgeEntryScreen(kind: kind, entry: entry) { next in
                                send(Edit.changing(nudges, kind, at: index, to: next))
                            }
                        } label: {
                            Label(Edit.words(entry), systemImage: "bell")
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { send(Edit.removing(nudges, kind, at: index)) }
                        }
                    }
                    if entries.count < Edit.maxEntries {
                        Button("Add a nudge") { send(Edit.adding(nudges, kind)) }
                    }
                } header: {
                    Text(kind.title)
                } footer: {
                    Text(kind.hint)
                }
            }
        }
        .navigationTitle("Nudges")
        .navigationBarTitleDisplayMode(.inline)
        .fixtureFact(
            "todosSettingsNudges", String(Edit.Kind.allCases.map { Edit.entries(nudges, $0).count }.reduce(0, +)))
    }

    private func send(_ next: TodoDefaultNudges) {
        TodoSettingsApply.send([TodoSettingsOps.defaultNudges(next)], store: store, toasts: toasts)
    }
}

/// One default nudge: how long before, in minutes, hours or days, and for days the time of day.
/// Saved when the screen is left.
struct TodoNudgeEntryScreen: View {
    let kind: TodoNudgeDefaultsEdit.Kind
    let entry: TodoDefaultNudges.Entry
    let save: (TodoDefaultNudges.Entry) -> Void

    private typealias Edit = TodoNudgeDefaultsEdit
    @State private var unit = TodoNudgeDefaultsEdit.Unit.days
    @State private var amount = 0
    @State private var time = Date()
    @State private var loaded = false

    private var edited: TodoDefaultNudges.Entry {
        let base = TodoDefaultNudges.Entry(minutes: entry.minutes, days: entry.days, time: TodoClock.text(time))
        return Edit.entry(unit: unit, amount: amount, keepingTimeOf: base)
    }

    var body: some View {
        Form {
            if kind.allowsMinutes {
                Picker("Counted in", selection: $unit) {
                    ForEach(Edit.Unit.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Stepper(
                value: $amount,
                in: 0...(unit == .days ? Edit.maxDays : unit == .hours ? Edit.maxMinutes / 60 : Edit.maxMinutes)
            ) {
                Text("\(amount) \(unit.rawValue) before")
            }
            if unit == .days {
                DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                    .environment(\.locale, ClockTime.pickerLocale)
                    .environment(\.timeZone, TodoClock.zone)
            }
            Section {
                Text(Edit.words(edited)).foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            unit = Edit.unit(of: entry)
            amount = Edit.amount(of: entry)
            time = TodoClock.date(entry.time ?? "17:00")
        }
        .onDisappear { if edited != entry { save(edited) } }
    }
}

// MARK: - Lists

struct TodoListsSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @State private var newName = ""
    @State private var newLayout = "list"

    private var store: TodosStore { environment.todos }

    var body: some View {
        Form {
            Section {
                ForEach(store.lists.filter { !$0.archived }) { list in
                    NavigationLink {
                        TodoListSettingsScreen(listId: list.id)
                    } label: {
                        HStack(spacing: 10) {
                            TodoIdentityIcon(identity: TodoIdentity.of(list: list))
                            Text(list.name).foregroundStyle(PaiPalette.Semantic.textStrong)
                            if list.locked {
                                Image(systemName: "lock").font(.caption).foregroundStyle(PaiPalette.Semantic.textFaint)
                            }
                            Spacer()
                            if list.members.count > 1 {
                                Label("\(list.members.count)", systemImage: "person.2").font(.caption)
                                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                            }
                            Text("\(list.counts.open) open").font(.caption).foregroundStyle(
                                PaiPalette.Semantic.textFaint)
                        }
                    }
                }
            }
            Section("New shared list") {
                TextField("Groceries", text: $newName)
                Picker("Layout", selection: $newLayout) {
                    Text("List").tag("list")
                    Text("Checklist").tag("checklist")
                }
                Button("Create list") {
                    TodoSettingsApply.send(
                        [TodoSettingsOps.listCreate(id: TodosStore.uuidv7(), name: newName, layout: newLayout)],
                        store: store,
                        toasts: toasts)
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .fixtureFact("todosSettingsLists", String(store.lists.filter { !$0.archived }.count))
    }
}

/// One list: its name, layout, look and lock for its owner, its people, and archiving it.
struct TodoListSettingsScreen: View {
    let listId: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var archiving = false

    private var store: TodosStore { environment.todos }
    private var list: TodoList? { store.lists.first { $0.id == listId } }

    var body: some View {
        Form {
            if let list {
                let own = TodoListRules.isOwnShared(list)
                Section {
                    if own {
                        TextField("Name", text: $name)
                            .submitLabel(.done)
                            .onSubmit { send([TodoSettingsOps.listRename(list, name)]) }
                        Picker(
                            "Layout",
                            selection: Binding(
                                get: { list.layout }, set: { send([TodoSettingsOps.listLayout(list, $0)]) })
                        ) {
                            Text("List").tag("list")
                            Text("Checklist").tag("checklist")
                        }
                    } else {
                        LabeledContent("Name", value: list.name)
                        LabeledContent("Kind", value: kindWord(list.kind))
                    }
                    if TodoListRules.canStyle(list) { look(list) }
                    if own {
                        Toggle(
                            "Locked",
                            isOn: Binding(get: { list.locked }, set: { send([TodoSettingsOps.listLocked(list, $0)]) }))
                    }
                } footer: {
                    if own { Text("A locked list takes no changes from anyone until it is unlocked.") }
                }
                peopleSection(list)
                if own {
                    Section {
                        Button("Archive \(list.name)", role: .destructive) { archiving = true }
                    }
                }
            } else {
                Text("This list is gone.").foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .navigationTitle(list?.name ?? "List")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = list?.name ?? "" }
        .onDisappear { if let list { send([TodoSettingsOps.listRename(list, name)]) } }
        .confirmationDialog("Archive this list?", isPresented: $archiving, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                if let list {
                    send([TodoSettingsOps.listArchive(list)])
                    dismiss()
                }
            }
        } message: {
            Text("Its todos leave every view. The list can be brought back on the web.")
        }
        .fixtureFact("todosSettingsMembers", String(list?.members.count ?? 0))
    }

    private func kindWord(_ kind: TodoListKind) -> String {
        switch kind {
        case .personal: "Personal"
        case .issues: "Issues"
        default: "Shared"
        }
    }

    @ViewBuilder private func look(_ list: TodoList) -> some View {
        Menu {
            Button("From its name") { send([TodoSettingsOps.listColor(list, nil)]) }
            ForEach(TodoColor.allCases, id: \.self) { color in
                Button(color.rawValue.capitalized) { send([TodoSettingsOps.listColor(list, color)]) }
            }
        } label: {
            HStack {
                Text("Colour").foregroundStyle(PaiPalette.Semantic.textStrong)
                Spacer()
                Circle().fill(TodoIdentity.of(list: list).color.swatch).frame(width: 16, height: 16)
            }
        }
        Menu {
            Button("By its kind") { send([TodoSettingsOps.listIcon(list, nil)]) }
            ForEach(TodoIcon.allCases, id: \.self) { icon in
                Button {
                    send([TodoSettingsOps.listIcon(list, icon)])
                } label: {
                    Label(icon.rawValue.capitalized, systemImage: icon.systemImage)
                }
            }
        } label: {
            HStack {
                Text("Symbol").foregroundStyle(PaiPalette.Semantic.textStrong)
                Spacer()
                TodoIdentityIcon(identity: TodoIdentity.of(list: list))
            }
        }
    }

    @ViewBuilder private func peopleSection(_ list: TodoList) -> some View {
        let manage = TodoListRules.canManageMembers(list)
        Section {
            ForEach(list.members, id: \.principal) { member in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName + (member.principal == store.me?.principal ? " (you)" : ""))
                            .foregroundStyle(PaiPalette.Semantic.textStrong)
                        if member.principal.hasPrefix("ns:") {
                            Text("Their agents").font(.caption).foregroundStyle(PaiPalette.Semantic.textFaint)
                        }
                    }
                    Spacer()
                    if manage, !TodoListRules.isLastOwner(member, of: list) {
                        Menu(TodoListRules.label(member.role)) {
                            ForEach(TodoListRules.grantableRoles, id: \.rawValue) { role in
                                Button(TodoListRules.label(role)) {
                                    send([TodoSettingsOps.setRole(list, of: member, to: role)])
                                }
                            }
                        }
                    } else {
                        Text(TodoListRules.label(member.role)).foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
                .swipeActions {
                    if manage, !TodoListRules.isLastOwner(member, of: list) {
                        Button("Remove", role: .destructive) { send([TodoSettingsOps.removeMember(list, member)]) }
                    }
                }
            }
            if manage {
                NavigationLink {
                    TodoShareScreen(listId: list.id)
                } label: {
                    Label("Add a person", systemImage: "person.badge.plus")
                }
            }
        } header: {
            Text("People")
        } footer: {
            if !manage {
                Text(
                    list.kind == .shared
                        ? "Only an owner can change who has access to this list."
                        : "This list is not shared; who can see it is decided for you.")
            }
        }
    }

    private func send(_ ops: [TodoOp?]) { TodoSettingsApply.send(ops, store: store, toasts: toasts) }
}

/// Shares a list with someone the server offers, or with an email address, in a role.
struct TodoShareScreen: View {
    let listId: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var role = TodoRole.editor
    @State private var people: [TodoPerson] = []

    private var store: TodosStore { environment.todos }
    private var list: TodoList? { store.lists.first { $0.id == listId } }

    private var matches: [TodoPerson] {
        guard let list else { return [] }
        let candidates = TodoListRules.candidates(people, for: list)
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? candidates : candidates.filter { $0.displayName.lowercased().contains(needle) }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name, or an email address", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                Picker(
                    "Role",
                    selection: Binding(
                        get: { role.rawValue }, set: { role = TodoRole.knownValues[$0] ?? .editor })
                ) {
                    ForEach(TodoListRules.grantableRoles, id: \.rawValue) {
                        Text(TodoListRules.label($0)).tag($0.rawValue)
                    }
                }
            } footer: {
                Text(TodoListRules.hint(role))
            }
            if let list {
                Section("People you share with") {
                    ForEach(matches) { person in
                        Button {
                            share(TodoSettingsOps.share(list, with: person, role: role), to: person.displayName)
                        } label: {
                            Label(person.displayName, systemImage: "person.badge.plus")
                        }
                    }
                    if TodoListRules.looksLikeEmail(text) {
                        Button("Share with \(text.trimmingCharacters(in: .whitespaces))") {
                            share(TodoSettingsOps.share(list, email: text, role: role), to: text)
                        }
                    }
                }
            }
        }
        .navigationTitle("Share \(list?.name ?? "")")
        .navigationBarTitleDisplayMode(.inline)
        .task { people = await store.people() }
    }

    private func share(_ op: TodoOp, to whom: String) {
        TodoSettingsApply.send([op], store: store, toasts: toasts)
        toasts.show("Shared \(list?.name ?? "the list") with \(whom.trimmingCharacters(in: .whitespaces))")
        dismiss()
    }
}

// MARK: - Tags

struct TodoTagsSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""

    private var store: TodosStore { environment.todos }
    private var tags: [TodoTag] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return (store.me?.tags ?? []).filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        List {
            let inUse = tags.filter { $0.openCount > 0 }
            let unused = tags.filter { $0.openCount == 0 }
            if !unused.isEmpty {
                Section {
                    ForEach(unused) { row($0) }
                } header: {
                    Text("On no open todo")
                } footer: {
                    Text("Tags no open todo carries. Delete the ones you do not need.")
                }
            }
            if !inUse.isEmpty {
                Section("In use") { ForEach(inUse) { row($0) } }
            }
            if tags.isEmpty {
                Text(query.isEmpty ? "No tags yet: type #name when adding a todo." : "No tag matches.")
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .searchable(text: $query, prompt: "Find a tag")
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .fixtureFact("todosSettingsTags", String(tags.count))
    }

    private func row(_ tag: TodoTag) -> some View {
        let list = store.lists.first { $0.id == tag.listId }
        let color = TodoIdentity.tagColor(tag.name, chosen: TodoIdentity.chosenTagColors(store.me?.tags ?? []))
        let content = HStack(spacing: 10) {
            Circle().fill(color.swatch).frame(width: 12, height: 12)
            Text(tag.name).foregroundStyle(PaiPalette.Semantic.textStrong)
            if tag.quiet { Text("quiet").font(.caption).foregroundStyle(PaiPalette.Semantic.textFaint) }
            Spacer()
            Text("\(tag.openCount) open").font(.caption).foregroundStyle(PaiPalette.Semantic.textFaint)
        }
        return Group {
            if TodoListRules.canEditTags(in: list) {
                NavigationLink {
                    TodoTagSettingsScreen(tagId: tag.id)
                } label: {
                    content
                }
            } else {
                content
            }
        }
    }
}

/// One tag: its name, colour and quiet, merging it into another of its list, deleting it.
struct TodoTagSettingsScreen: View {
    let tagId: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var deleting = false

    private var store: TodosStore { environment.todos }
    private var tags: [TodoTag] { store.me?.tags ?? [] }
    private var tag: TodoTag? { tags.first { $0.id == tagId } }

    var body: some View {
        Form {
            if let tag {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { send([TodoSettingsOps.tagRename(tag, name)]) }
                    Menu {
                        Button("From its name or its parent's") { send([TodoSettingsOps.tagColor(tag, nil)]) }
                        ForEach(TodoColor.allCases, id: \.self) { color in
                            Button(color.rawValue.capitalized) { send([TodoSettingsOps.tagColor(tag, color)]) }
                        }
                    } label: {
                        HStack {
                            Text("Colour").foregroundStyle(PaiPalette.Semantic.textStrong)
                            Spacer()
                            Circle()
                                .fill(
                                    TodoIdentity.tagColor(tag.name, chosen: TodoIdentity.chosenTagColors(tags)).swatch
                                )
                                .frame(width: 16, height: 16)
                        }
                    }
                    Toggle(
                        "Quiet", isOn: Binding(get: { tag.quiet }, set: { send([TodoSettingsOps.tagQuiet(tag, $0)]) }))
                } footer: {
                    Text("A quiet tag keeps its todos out of views that do not name it.")
                }
                let siblings = tags.filter { $0.listId == tag.listId && $0.id != tag.id }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
                if !siblings.isEmpty {
                    Section {
                        Menu("Merge into…") {
                            ForEach(siblings) { other in
                                Button(other.name) {
                                    send([TodoSettingsOps.tagMerge(tag, into: other)])
                                    dismiss()
                                }
                            }
                        }
                    } footer: {
                        Text("Its todos take the other tag instead, and this one goes.")
                    }
                }
                Section {
                    Button("Delete \(tag.name)", role: .destructive) { deleting = true }
                } footer: {
                    Text(
                        "\(tag.openCount) open todo\(tag.openCount == 1 ? "" : "s") carry it; they keep everything else."
                    )
                }
            } else {
                Text("This tag is gone.").foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .navigationTitle(tag.map { "#\($0.name)" } ?? "Tag")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = tag?.name ?? "" }
        .confirmationDialog("Delete this tag?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let tag {
                    send([TodoSettingsOps.tagDelete(tag)])
                    dismiss()
                }
            }
        }
    }

    private func send(_ ops: [TodoOp?]) { TodoSettingsApply.send(ops, store: store, toasts: toasts) }
}

// MARK: - Views

/// Every saved view in its order: a tap edits one, the star makes it a favourite, Edit drags
/// them into another order, and the plus makes a new one.
struct TodoViewsSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @State private var adding = false

    private var store: TodosStore { environment.todos }

    var body: some View {
        let views = (store.me?.views ?? []).sorted { $0.rank < $1.rank }
        let chosen = TodoIdentity.chosenTagColors(store.me?.tags ?? [])
        let tagColor = { (name: String) in TodoIdentity.tagColor(name, chosen: chosen) }
        List {
            Section {
                ForEach(views) { view in
                    row(view, identity: TodoIdentity.of(view: view, tagColor: tagColor))
                }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    send([TodoSettingsOps.viewMove(views, from: from, to: destination)])
                }
            } footer: {
                Text("A favourite is listed first in Views and lists; the first one is where Todos opens.")
            }
        }
        .navigationTitle("Views")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New view")
            }
        }
        .navigationDestination(isPresented: $adding) { TodoViewSettingsScreen(viewId: nil) }
        .task { openFixtureState() }
        .fixtureFact("todosSettingsViews", String(views.count))
    }

    private func row(_ view: TodoView, identity: TodoIdentity) -> some View {
        NavigationLink {
            TodoViewSettingsScreen(viewId: view.id)
        } label: {
            HStack(spacing: 10) {
                TodoIdentityIcon(identity: identity)
                Text(view.name).foregroundStyle(PaiPalette.Semantic.textStrong)
                Spacer()
                Button {
                    send([TodoSettingsOps.favourite(view, !view.pinned)])
                } label: {
                    Image(systemName: view.pinned ? "star.fill" : "star")
                        .foregroundStyle(view.pinned ? TodoColor.amber.swatch : PaiPalette.Semantic.textFaint)
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                // Borderless, so the star takes its own tap inside the row's link.
                .buttonStyle(.borderless)
                .accessibilityLabel(view.pinned ? "Remove from the favourites" : "Make a favourite")
            }
        }
    }

    private func send(_ ops: [TodoOp?]) { TodoSettingsApply.send(ops, store: store, toasts: toasts) }

    private func openFixtureState() {
        #if DEBUG
            if PaiFixtureLaunch.requestedTodosSettings() == "view-new" { adding = true }
        #endif
    }
}

/// One view: its name, its query and whether it is a favourite; deleting it. `viewId` nil is a
/// view being made. Nothing is sent before Save, and a refusal (a query the server cannot read)
/// is said under the fields with everything typed still there.
struct TodoViewSettingsScreen: View {
    let viewId: String?

    @Environment(AppEnvironment.self) private var environment
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var pinned = true
    @State private var loaded = false
    @State private var saving = false
    @State private var refusal: String?
    @State private var deleting = false
    @State private var discarding = false

    private var store: TodosStore { environment.todos }
    private var view: TodoView? { viewId.flatMap { id in store.me?.views.first { $0.id == id } } }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var changed: Bool {
        guard let view else { return !trimmedName.isEmpty || !trimmedQuery.isEmpty }
        return trimmedName != view.name || trimmedQuery != view.query || pinned != view.pinned
    }

    private var canSave: Bool { changed && !trimmedName.isEmpty && !saving }

    var body: some View {
        Form {
            if viewId != nil && view == nil {
                Text("This view is gone.").foregroundStyle(PaiPalette.Semantic.textMuted)
            } else {
                fields
                if let view, view.builtin == nil {
                    Section {
                        Button("Delete \(view.name)", role: .destructive) { deleting = true }
                    } footer: {
                        Text("Only the view goes. Its todos stay where they are.")
                    }
                }
            }
        }
        .navigationTitle(view?.name ?? (viewId == nil ? "New view" : "View"))
        .navigationBarTitleDisplayMode(.inline)
        // With something unsaved the way back asks first, so a swipe cannot drop what was typed.
        .navigationBarBackButtonHidden(changed)
        .toolbar {
            if changed {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discarding = true } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!canSave)
            }
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete this view?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { remove() }
        }
        .confirmationDialog("Discard what you changed?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .fixtureFact("todosSettingsView", viewId == nil ? "new" : (view?.name ?? "gone"))
    }

    @ViewBuilder private var fields: some View {
        Section("Name") {
            TextField("Name", text: $name).submitLabel(.done)
        }
        Section {
            TextField("tag:home horizon:<=week", text: $query, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Query")
        } footer: {
            Text("What the view shows, in the words the search box takes. Empty shows every open todo.")
        }
        Section {
            Toggle("Favourite", isOn: $pinned)
        }
        if let refusal {
            Section {
                Text(refusal).foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let view {
            name = view.name
            query = view.query
            pinned = view.pinned
        }
    }

    private func save() {
        let op = TodoSettingsOps.viewSave(
            id: view?.id ?? TodosStore.uuidv7(), name: name, query: query,
            layout: view?.layout ?? TodoSettingsOps.newViewLayout, pinned: pinned)
        apply(op)
    }

    private func remove() {
        guard let view else { return }
        apply(TodoSettingsOps.viewDelete(view))
    }

    /// Sends one change and leaves once the server took it; a refusal stays on the screen.
    private func apply(_ op: TodoOp) {
        saving = true
        refusal = nil
        Task {
            let settlement = await store.applySettings([op])
            saving = false
            switch settlement {
            case .applied:
                dismiss()
            case .refused(let refused):
                refusal = refused.message
            case .waiting:
                toasts.show("Saved on this iPhone. It is sent once there is a connection.", kind: .info)
                dismiss()
            }
        }
    }
}
