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
            groupBy: String = "none"
        ) -> [String: Any] {
            [
                "id": String(format: "0190f000-0000-7000-8000-00000000b%03d", n), "name": name, "icon": null,
                "builtin": builtin, "layout": layout, "query": query, "group_by": groupBy, "sort": "hand",
                "tree": "fold",
                "display": [String: Any](), "pinned": pinned, "rank": String(format: "a%03d", n),
                "defaults": [String: Any](),
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
            ],
            "tags": [
                tag(1, "home"), tag(2, "home/garden"), tag(3, "errand"), tag(4, "family"),
                tag(5, "money", color: "violet"),
                tag(6, "paperwork"), tag(7, "travel"), tag(8, "kitchen"),
            ],
            "views": [
                view(1, "Today", builtin: "today", layout: "today", query: "is:today -is:desk", pinned: true),
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
    public static func todosRoute(method: String, path: String, body: Data?) -> (status: Int, body: Data)? {
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
        case ("POST", "/query"):
            let q = request?["q"] as? String ?? ""
            if q.hasPrefix("list:") {
                let list = String(q.dropFirst(5))
                return (200, todosJSON(todosQueryAnswer(todosCorpus.filter { $0.list == list && $0.parent == nil })))
            }
            return (200, todosJSON(todosQueryAnswer(todosCorpus)))
        case ("POST", "/parse"): return (200, todosJSON(todosParse(request?["text"] as? String ?? "")))
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
            let children = todosCorpus.filter { $0.parent == ref }.map(\.json)
            return (200, todosJSON(["todo": todo.json, "children": children, "nudges": []]))
        }
        return nil
    }

    /// The fixture's reading of a capture line: `#tags`, `tomorrow`, `now`/`p1` and `*` for the
    /// desk, enough to photograph the add sheet's chips; the rest stays in the title.
    static func todosParse(_ text: String) -> [String: Any] {
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
            "tokens": tokens, "issues": [],
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
}
