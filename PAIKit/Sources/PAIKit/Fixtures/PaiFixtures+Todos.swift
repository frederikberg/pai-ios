import Foundation

/// The Todos routes for fixture mode: one person with three lists, a handful of tags, the built-in
/// views and two of their own, a desk with a section, and todos with every mark a row can carry
/// (horizons, tags, a date, a description, subtasks). Content is invented. The day is fixed, so a
/// screenshot reads the same whenever it is taken.
extension PaiFixtures {

    public static let todosDay = "2026-11-26"
    public static let todosPersonalList = "0190f000-0000-7000-8000-00000000a001"
    public static let todosGroceriesList = "0190f000-0000-7000-8000-00000000a002"
    public static let todosFlatList = "0190f000-0000-7000-8000-00000000a003"
    public static let todosTodayView = "0190f000-0000-7000-8000-00000000b001"
    public static let todosHomeView = "0190f000-0000-7000-8000-00000000b006"
    public static let todosUpcomingView = "0190f000-0000-7000-8000-00000000b002"
    public static let todosLogbookView = "0190f000-0000-7000-8000-00000000b005"
    /// The todo whose subtasks the checklist screenshot opens.
    public static let todosParent = "0190f000-0000-7000-8000-00000000c009"

    struct FixtureTodo {
        let n: Int
        let title: String
        var list = todosPersonalList
        var horizon = "whenever"
        var tags: [String] = []
        var preview = ""
        var when: String?
        var time: String?
        var deadline: String?
        var parent: String?
        var children = 0
        var desk = false
        var checklist: (Int, Int)?

        var id: String { String(format: "0190f000-0000-7000-8000-00000000c%03d", n) }

        var json: [String: Any] {
            let null = NSNull()
            return [
                "id": id, "number": n, "ref": "T-\(n)", "list_id": list, "parent_id": parent ?? null,
                "root_id": parent ?? id, "depth": parent == nil ? 0 : 1, "rank": String(format: "a%03d", n),
                "title": title,
                "body_preview": preview, "body": null, "body_hash": String(repeating: "0", count: 64), "status": "open",
                "inbox": false, "horizon": horizon,
                "when": when.map { ["date": $0, "time": time ?? null] as [String: Any] } ?? null, "someday": false,
                "deadline": deadline.map { ["date": $0, "lead_days": null] as [String: Any] } ?? null, "repeat": null,
                "tags": tags, "inherited_tags": [], "links": [], "attachments": [], "children_open": children,
                "children_total": children,
                "checklist": checklist.map { ["done": $0.0, "total": $0.1] as [String: Any] } ?? null,
                "completed_at": null, "completed_count": 0, "last_done_at": null, "key": null,
                "created": [
                    "at": "2026-11-20T09:00:00.000001+00:00", "by": "user:0190f000-0000-7000-8000-00000000f001",
                    "kind": "human", "label": "Sam", "source": "web", "session_id": null,
                ],
                "updated_at": "2026-11-25T09:00:00.000001+00:00", "updated_seq": 100 + n, "version": 1, "asleep": false,
                "in_band": when == todosDay, "on_desk": desk, "has_nudge": false, "context": null, "folded_ids": null,
            ]
        }
    }

    static let todosCorpus: [FixtureTodo] = [
        FixtureTodo(n: 1, title: "Return the drill to the neighbours", horizon: "now", tags: ["errand"], desk: true),
        FixtureTodo(
            n: 2, title: "Book the train to the coast", horizon: "week", preview: "Window seat, morning.", desk: true),
        FixtureTodo(n: 3, title: "Repot the basil", tags: ["home/garden"], desk: true),
        FixtureTodo(
            n: 4, title: "Call the plumber about the kitchen tap", horizon: "now", tags: ["home"], when: todosDay,
            time: "17:00", desk: true),
        FixtureTodo(n: 5, title: "Write the thank-you cards", horizon: "soon", tags: ["family"], desk: true),
        FixtureTodo(n: 6, title: "Renew the library card", horizon: "week", deadline: "2026-11-28"),
        FixtureTodo(
            n: 7, title: "Sort the receipts for the tax return", horizon: "soon", tags: ["money", "paperwork"],
            preview: "The folder on the shelf.", when: todosDay),
        FixtureTodo(n: 8, title: "Fix the bike light", horizon: "now", tags: ["errand"], when: "2026-11-27"),
        FixtureTodo(
            n: 9, title: "Pack for the weekend trip", horizon: "week", tags: ["travel"], preview: "Leave on Friday.",
            when: "2026-11-28", children: 3),
        FixtureTodo(n: 10, title: "Socks and the warm jumper", horizon: "week", parent: todosParent),
        FixtureTodo(n: 11, title: "Raincoat", horizon: "week", parent: todosParent),
        FixtureTodo(n: 12, title: "Phone charger", horizon: "week", parent: todosParent),
        FixtureTodo(
            n: 13, title: "Plan the garden beds for spring", tags: ["home/garden"], preview: "Sketch first, buy later.",
            checklist: (1, 4)),
        FixtureTodo(n: 14, title: "Descale the kettle", horizon: "soon", tags: ["home", "kitchen"]),
        FixtureTodo(n: 20, title: "Oat milk", list: todosGroceriesList),
        FixtureTodo(n: 21, title: "Rye bread", list: todosGroceriesList),
        FixtureTodo(n: 22, title: "Apples", list: todosGroceriesList),
        FixtureTodo(n: 23, title: "Coffee beans", list: todosGroceriesList),
        FixtureTodo(n: 24, title: "Dish soap", list: todosGroceriesList),
        FixtureTodo(n: 30, title: "Buy a new shower curtain", list: todosFlatList, horizon: "week", tags: ["home"]),
        FixtureTodo(n: 31, title: "Take the bottles back", list: todosFlatList, horizon: "soon"),
    ]

    private static func todosJSON(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }

    private static func todosTodo(_ id: String) -> FixtureTodo? { todosCorpus.first { $0.id == id } }

    static func todosMe() -> [String: Any] {
        let null = NSNull()
        let me: [String: Any] = [
            "principal": "user:0190f000-0000-7000-8000-00000000f001", "role": "owner", "display_name": "Sam",
        ]
        func list(
            _ id: String, _ name: String, kind: String, layout: String = "list", icon: Any = null, color: Any = null
        )
            -> [String: Any]
        {
            [
                "id": id, "name": name, "kind": kind, "layout": layout, "icon": icon, "color": color, "locked": false,
                "archived": false, "role": "owner", "members": [me],
                "counts": ["open": todosCorpus.filter { $0.list == id }.count],
            ]
        }
        func tag(_ n: Int, _ name: String, color: Any = null) -> [String: Any] {
            [
                "id": String(format: "0190f000-0000-7000-8000-00000000d%03d", n), "list_id": todosPersonalList,
                "name": name, "color": color, "icon": null, "quiet": false,
                "open_count": todosCorpus.filter { $0.tags.contains(name) }.count,
            ]
        }
        func view(
            _ n: Int, _ name: String, builtin: Any = null, layout: String = "list", query: String, pinned: Bool,
            groupBy: String = "none", defaults: [String: Any] = [:]
        ) -> [String: Any] {
            [
                "id": String(format: "0190f000-0000-7000-8000-00000000b%03d", n), "name": name, "icon": null,
                "builtin": builtin, "layout": layout, "query": query, "group_by": groupBy, "sort": "hand",
                "tree": "fold",
                "display": [String: Any](), "pinned": pinned, "rank": String(format: "a%03d", n),
                "defaults": defaults,
            ]
        }
        return [
            "principal": "user:0190f000-0000-7000-8000-00000000f001", "user_id": "0190f000-0000-7000-8000-00000000f001",
            "display_name": "Sam", "actor_kind": "human", "seq": 200,
            "lists": [
                list(todosPersonalList, "Personal", kind: "personal"),
                list(todosGroceriesList, "Groceries", kind: "shared", layout: "checklist", icon: "cart", color: "teal"),
                list(todosFlatList, "Flat share", kind: "shared"),
            ],
            "prefs": [
                "timezone": "Europe/Berlin", "day_rollover": "03:30", "deadline_lead_days": 3,
                "default_list_id": todosPersonalList, "scopes": [], "active_scope": null, "seen_seq": 0,
                "default_nudges": [
                    "timed": [["minutes": 15, "days": null, "time": null]],
                    "day": [["minutes": null, "days": 1, "time": "17:00"]], "deadline": [],
                ],
            ],
            "tags": [
                tag(1, "home"), tag(2, "home/garden"), tag(3, "errand"), tag(4, "family"),
                tag(5, "money", color: "violet"),
                tag(6, "paperwork"), tag(7, "travel"), tag(8, "kitchen"),
            ],
            "views": [
                view(
                    1, "Today", builtin: "today", layout: "today", query: "is:today -is:desk", pinned: true,
                    defaults: ["when": "today"]),
                view(
                    2, "Upcoming", builtin: "upcoming", layout: "agenda",
                    query: "is:open (when:>today OR deadline:>today)", pinned: true),
                view(3, "All", builtin: "all", query: "is:root", pinned: true, groupBy: "horizon"),
                view(4, "Inbox", builtin: "inbox", query: "is:inbox", pinned: true),
                view(5, "Logbook", builtin: "logbook", layout: "log", query: "is:done OR is:dropped", pinned: true),
                view(6, "Home", query: "tag:home", pinned: true),
                view(7, "Focus", query: "horizon:now", pinned: true),
                view(8, "Chrono", builtin: "chrono", query: "is:open", pinned: false),
            ],
        ]
    }

    static func todosToday() -> [String: Any] {
        let onDesk = todosCorpus.filter(\.desk)
        var desk: [[String: Any]] = []
        for (index, todo) in onDesk.enumerated() {
            if index == 3 {
                desk.append([
                    "id": "0190f000-0000-7000-8000-00000000e900", "kind": "divider", "todo_id": NSNull(),
                    "title": "Evening",
                    "rank": "m", "added_at": "2026-11-26T07:00:00.000001+00:00", "added_day": todosDay,
                ])
            }
            desk.append([
                "id": String(format: "0190f000-0000-7000-8000-00000000e%03d", todo.n), "kind": "todo",
                "todo_id": todo.id,
                "title": NSNull(), "rank": String(format: "a%03d", index),
                "added_at": "2026-11-26T07:00:00.000001+00:00",
                "added_day": todosDay,
            ])
        }
        let due = todosCorpus.filter { !$0.desk && $0.when == todosDay }
        return [
            "desk": desk, "todos": Dictionary(uniqueKeysWithValues: onDesk.map { ($0.id, $0.json) }),
            "due": due.map(\.json), "seq": 200, "day": todosDay,
        ]
    }

    /// The rows a view's run answers, by the view's query as the corpus reads it.
    static func todosRun(viewId: String) -> [String: Any] {
        let roots = todosCorpus.filter { $0.parent == nil && $0.list == todosPersonalList }
        let rows: [FixtureTodo]
        var groups: [[String: Any]] = []
        switch viewId {
        case todosTodayView:
            rows = todosCorpus.filter { todo in
                !todo.desk
                    && (todo.when == todosDay || todo.deadline.map { TodoDates.dayDiff(todosDay, $0) <= 3 } == true)
            }
        case todosHomeView: rows = todosCorpus.filter { $0.tags.contains { $0 == "home" || $0.hasPrefix("home/") } }
        case String(format: "0190f000-0000-7000-8000-00000000b%03d", 7):
            rows = todosCorpus.filter { $0.horizon == "now" }
        case String(format: "0190f000-0000-7000-8000-00000000b%03d", 3):
            rows = roots
            for (key, label) in [("now", "Now"), ("week", "This week"), ("soon", "Soon"), ("whenever", "Whenever")] {
                let ids = roots.filter { $0.horizon == key }.map(\.id)
                if !ids.isEmpty { groups.append(["key": key, "label": label, "ids": ids]) }
            }
        default: rows = roots
        }
        return todosQueryAnswer(rows, groups: groups)
    }

    private static func todosQueryAnswer(_ rows: [FixtureTodo], groups: [[String: Any]] = []) -> [String: Any] {
        [
            "todos": rows.map(\.json), "groups": groups, "total": rows.count, "next_cursor": NSNull(), "seq": 200,
            "explain": ["normalized": "", "defaults": []],
        ]
    }

    /// Answers a Todos request in fixture mode; nil for a path the corpus has no answer for.
    public static func todosRoute(
        method: String, path: String, query: [URLQueryItem] = [], body: Data?
    ) -> (status: Int, body: Data)? {
        guard path.hasPrefix("/api/todos/") else { return nil }
        let rest = String(path.dropFirst("/api/todos".count))
        let request = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        switch (method, rest) {
        case ("GET", "/me"): return (200, todosJSON(todosMe()))
        case ("GET", "/today"): return (200, todosJSON(todosToday()))
        case ("GET", "/views/counts"):
            let views = (todosMe()["views"] as? [[String: Any]]) ?? []
            let counts = views.map { view -> [String: Any] in
                let id = view["id"] as? String ?? ""
                let days = ["upcoming", "logbook"].contains(view["builtin"] as? String ?? "")
                let total = (todosRun(viewId: id)["total"] as? Int) ?? 0
                return ["id": id, "count": days ? NSNull() : total]
            }
            return (200, todosJSON(["views": counts, "seq": 200]))
        case ("GET", "/events"): return (200, todosJSON(["events": [], "head": 200, "reset": false]))
        case ("GET", "/upcoming"): return (200, todosJSON(todosUpcoming()))
        case ("GET", "/logbook"): return (200, todosJSON(todosLogbook()))
        case ("POST", "/search"): return (200, todosJSON(todosSearch(request?["q"] as? String ?? "")))
        case ("POST", "/query"):
            let q = request?["q"] as? String ?? ""
            if q.hasPrefix("list:") {
                let list = String(q.dropFirst(5))
                return (200, todosJSON(todosQueryAnswer(todosCorpus.filter { $0.list == list && $0.parent == nil })))
            }
            return (200, todosJSON(todosQueryAnswer(todosCorpus)))
        case ("POST", "/parse"): return (200, todosJSON(todosParse(request?["text"] as? String ?? "")))
        case ("POST", "/compose"): return (200, todosJSON(todosCompose(request?["text"] as? String ?? "")))
        case ("POST", "/apply"): return (200, todosJSON(todosApplied(request ?? [:])))
        default: break
        }
        if method == "GET", rest.hasPrefix("/views/"), rest.hasSuffix("/run") {
            let id = String(rest.dropFirst("/views/".count).dropLast("/run".count))
            return (200, todosJSON(todosRun(viewId: id)))
        }
        if method == "GET", rest.hasPrefix("/todos/") {
            let ref = String(rest.dropFirst("/todos/".count))
            guard let todo = todosTodo(ref) else {
                return (404, todosJSON(["error": "not_found", "message": "No todo '\(ref)' you can see.", "ref": ref]))
            }
            var children = todosCorpus.filter { $0.parent == ref }.map(\.json)
            if ref == todosParent, query.contains(where: { $0.name == "closed" && $0.value == "1" }) {
                var done = FixtureTodo(n: 15, title: "Passport", horizon: "week", parent: todosParent).json
                done["status"] = "done"
                done["completed_at"] = "2026-11-25T18:00:00.000001+00:00"
                children.append(done)
            }
            return (
                200,
                todosJSON([
                    "todo": todosDetailRow(todo), "children": children,
                    "nudges": ref == todosParent ? todosNudges(for: ref) : [],
                    "history": todosHistory(for: todo),
                ])
            )
        }
        return nil
    }

    /// The fixture's reading of a capture line: `#tags`, `tomorrow`, `now`/`p1`, `*` for the desk
    /// and a closing "no date", enough to photograph the add sheet's chips; the rest stays in the
    /// title.
    static func todosParse(_ text: String) -> [String: Any] {
        var text = text
        var clears: [String] = []
        var clearToken: [[String: Any]] = []
        if text.lowercased().hasSuffix(" no date") {
            let start = text.utf16.count - "no date".utf16.count
            clears = ["when"]
            clearToken = [
                ["start": start, "end": text.utf16.count, "kind": "clear", "value": "when", "display": "No date"]
            ]
            text = String(text.dropLast(" no date".count))
        }
        var title: [Substring] = []
        var tags: [String] = []
        var tokens: [[String: Any]] = []
        var when: Any = NSNull()
        var horizon: Any = NSNull()
        var desk = false
        var offset = 0
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let start = offset
            let end = start + word.utf16.count
            offset = end + 1
            if word.hasPrefix("#"), word.count > 1 {
                tags.append(String(word.dropFirst()))
                tokens.append([
                    "start": start, "end": end, "kind": "tag", "value": String(word.dropFirst()),
                    "display": String(word),
                ])
            } else if word.lowercased() == "tomorrow" {
                when = ["date": "2026-11-27", "time": NSNull()]
                tokens.append(["start": start, "end": end, "kind": "when", "value": when, "display": "Fri 27 Nov"])
            } else if word.lowercased() == "p1" {
                horizon = "now"
                tokens.append(["start": start, "end": end, "kind": "horizon", "value": "now", "display": "now"])
            } else if word == "*" {
                desk = true
                tokens.append(["start": start, "end": end, "kind": "desk", "value": true, "display": "Desk"])
            } else {
                title.append(word)
            }
        }
        let words = title.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let null = NSNull()
        return [
            "title": words,
            "fields": [
                "tags": tags, "horizon": horizon, "when": when, "deadline": null, "repeat": null, "parent": null,
                "list": null, "desk": desk, "nudges": [],
            ],
            "tokens": tokens + clearToken, "issues": [], "clears": clears,
            "create_op": [
                "op": "todo.create", "id": UUID().uuidString.lowercased(), "title": words, "list": null, "tags": tags,
                "horizon": horizon, "when": when, "desk": desk ? true : null,
            ],
        ]
    }

    /// `/apply` taken as asked: every op applied, the change numbered after the corpus.
    static func todosApplied(_ request: [String: Any]) -> [String: Any] {
        let ops = request["ops"] as? [[String: Any]] ?? []
        let null = NSNull()
        return [
            "change": [
                "id": request["change_id"] as? String ?? UUID().uuidString.lowercased(), "seq_first": 201,
                "seq_last": 201,
                "actor": ["principal": "user:0190f000-0000-7000-8000-00000000f001", "kind": "human", "label": "Sam"],
                "source": "ios", "session_id": null, "summary": "", "op_count": ops.count, "undo_of": null,
                "undone_by": null, "created_at": "2026-11-26T10:00:00.000001+00:00", "events": null,
            ],
            "applied": ops.count, "of": ops.count,
            "results": ops.indices.map {
                ["index": $0, "ok": true, "ref": null, "id": null, "error": null] as [String: Any]
            },
            "todos": [], "events": [], "replayed": false,
        ]
    }

    /// The todo as `GET /todos/{ref}` answers it: with its whole description, which for the todo
    /// with subtasks is markdown (a heading, a list with a task box, a link, emphasis), so the sheet
    /// photographs it rendered.
    static func todosDetailRow(_ todo: FixtureTodo) -> [String: Any] {
        var row = todo.json
        if todo.id == todosParent {
            row["body"] = """
                ## Before the trip
                Pack the **warm** jacket and check the [timetable](https://example.org/timetable).

                - [x] Book the hostel
                - [ ] Charge the camera
                - Ask about the *late* check-in
                """
            row["body_preview"] = "## Before the trip"
        } else {
            row["body"] = todo.preview
        }
        return row
    }

    /// One nudge added by hand and one the person's default nudges made, days before at 17:00.
    static func todosNudges(for ref: String) -> [[String: Any]] {
        [
            [
                "id": "0190f000-0000-7000-8000-00000000f101", "todo_id": ref, "kind": "before", "date": NSNull(),
                "time": NSNull(), "basis": "when", "offset_minutes": 60, "days": NSNull(), "origin": NSNull(),
                "fire_at": "2026-11-28T08:00:00.000001+00:00", "state": "armed",
            ],
            [
                "id": "0190f000-0000-7000-8000-00000000f102", "todo_id": ref, "kind": "before", "date": NSNull(),
                "time": "17:00", "basis": "when", "offset_minutes": NSNull(), "days": 1, "origin": "default",
                "fire_at": "2026-11-27T16:00:00.000001+00:00", "state": "armed",
            ],
        ]
    }

    /// The fixture's model: each sentence (split at ". " and " and then ") is one todo, the
    /// parser's fixture reading its words, so the add sheet's describe mode can be photographed.
    static func todosCompose(_ text: String) -> [String: Any] {
        let sentences = text.components(separatedBy: " and then ").flatMap { $0.components(separatedBy: ". ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))) }
            .filter { !$0.isEmpty }
        let ops = sentences.map { sentence -> [String: Any] in
            var op = (todosParse(sentence)["create_op"] as? [String: Any]) ?? [:]
            if (op["title"] as? String ?? "").isEmpty { op["title"] = sentence }
            return op
        }
        return ["ops": ops, "model": "fixture"]
    }

    static func todosHistory(for todo: FixtureTodo) -> [[String: Any]] {
        func change(_ n: Int, _ summary: String, label: String, at: String) -> [String: Any] {
            [
                "id": String(format: "0190f000-0000-7000-8000-00000000f2%02d", n), "seq_first": 100 + n,
                "seq_last": 100 + n,
                "actor": ["principal": "user:0190f000-0000-7000-8000-00000000f001", "kind": "human", "label": label],
                "source": n == 2 ? "ios" : "web", "session_id": NSNull(), "summary": summary, "op_count": 1,
                "undo_of": NSNull(), "undone_by": NSNull(), "created_at": at, "events": NSNull(),
            ]
        }
        return [
            change(2, "Set T-\(todo.n)'s day", label: "Sam", at: "2026-11-25T09:00:00.000001+00:00"),
            change(1, "Created T-\(todo.n) \(todo.title)", label: "Sam", at: "2026-11-20T09:00:00.000001+00:00"),
        ]
    }

    /// The days ahead from the corpus: each open root by its day or deadline, a repeat's ghost,
    /// the undated ones under Someday.
    static func todosUpcoming() -> [String: Any] {
        let roots = todosCorpus.filter { $0.parent == nil && $0.list != todosGroceriesList }
        var days: [[String: Any]] = []
        for offset in 1...14 {
            let date = TodoWords.addDays(todosDay, offset)
            let planned = roots.filter { $0.when == date }.map(\.id)
            let due = roots.filter { $0.deadline == date }.map(\.id)
            let ghosts: [[String: Any]] =
                TodoWords.weekday(date) == 1 ? [["todo_id": todosCorpus[13].id, "date": date]] : []
            days.append(["date": date, "todos": planned, "deadlines": due, "ghosts": ghosts])
        }
        let undated = roots.filter { $0.when == nil && $0.deadline == nil }.prefix(3).map(\.id)
        return [
            "days": days, "later": [], "someday": Array(undated),
            "todos": Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.json) }), "seq": 200,
        ]
    }

    /// Completions of the last days, closed copies of corpus todos.
    static func todosLogbook() -> [String: Any] {
        let picks: [(Int, String, String)] = [
            (40, "Send the parcel back", "2026-11-26"), (41, "Pay the electricity bill", "2026-11-26"),
            (42, "Water the plants", "2026-11-25"), (43, "Buy birthday candles", "2026-11-24"),
        ]
        var todos: [String: Any] = [:]
        var days: [String: [[String: Any]]] = [:]
        for (n, title, day) in picks {
            var row = FixtureTodo(n: n, title: title, horizon: "week").json
            row["status"] = n == 43 ? "dropped" : "done"
            row["completed_at"] = "\(day)T16:00:00.000001+00:00"
            todos[row["id"] as? String ?? ""] = row
            days[day, default: []].append([
                "completion_id": String(format: "0190f000-0000-7000-8000-00000000f3%02d", n),
                "todo_id": row["id"] ?? "",
                "kind": n == 43 ? "dropped" : "done", "at": "\(day)T16:00:00.000001+00:00", "by_label": "Sam",
            ])
        }
        let ordered = days.keys.sorted(by: >).map { ["date": $0, "entries": days[$0] ?? []] as [String: Any] }
        return ["days": ordered, "todos": todos, "next_cursor": NSNull()]
    }

    /// The search box's answer: corpus todos whose title holds a typed word, the word marked.
    static func todosSearch(_ q: String) -> [String: Any] {
        let words = q.lowercased().split(separator: " ").map(String.init).filter { !$0.contains(":") }
        let hits = todosCorpus.filter { todo in
            !words.isEmpty && words.allSatisfy { todo.title.lowercased().contains($0) }
        }.map { todo -> [String: Any] in
            var parts: [[String: Any]] = []
            var rest = Substring(todo.title)
            if let word = words.first, let range = rest.range(of: word, options: .caseInsensitive) {
                parts.append(["t": String(rest[..<range.lowerBound]), "m": false])
                parts.append(["t": String(rest[range]), "m": true])
                rest = rest[range.upperBound...]
            }
            parts.append(["t": String(rest), "m": false])
            return ["todo": todo.json, "title_parts": parts, "snippet": NSNull(), "breadcrumb": []]
        }
        let tags = (todosMe()["tags"] as? [[String: Any]] ?? []).filter { tag in
            words.contains { (tag["name"] as? String ?? "").contains($0) }
        }
        return [
            "query": [
                "raw": q, "normalized": q, "structured": false, "tokens": [], "issues": [], "pending": NSNull(),
                "corrections": [], "defaults": [],
            ],
            "top": NSNull(), "todos": hits, "fewer": [],
            "counts": ["open": hits.count, "closed": 0, "deleted": 0, "capped": false],
            "tags": tags.map { ["tag": $0, "parts": [["t": $0["name"] ?? "", "m": true]]] }, "views": [], "lists": [],
            "offers": [["kind": "create", "label": "Add \u{201C}\(q)\u{201D} as a todo", "q": q]],
            "next_cursor": NSNull(), "seq": 200, "took_ms": 4, "partial": false,
        ]
    }
}
