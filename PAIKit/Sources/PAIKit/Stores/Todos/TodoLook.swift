import Foundation

/// Todos' one set of colours and symbols for things a person names (tags, views, lists) and for
/// the horizons, the web's `shell/palette.ts`, `shell/identity.ts`, `shell/icons.ts` and
/// `shell/horizon.tsx` by the same rules (pai-cloud `docs/architecture/todos.md` → *Colour and
/// symbols*), so a tag wears the same colour on the phone and in the browser.
public enum TodoColor: String, CaseIterable, Codable, Sendable {
    case rose, orange, amber, lime, emerald, teal, sky, blue, indigo, violet, fuchsia, slate

    /// One value per theme: light, then dark. `#rrggbb` or `#rrggbbaa`.
    public struct Pair: Equatable, Sendable {
        public let light: String
        public let dark: String
    }

    /// The parts of a colour an element wears: a solid fill (pickers, rings), an ink for an icon or
    /// a mark on the page, and a chip's pale fill and its text.
    public struct Hue: Equatable, Sendable {
        public let swatch: Pair
        public let ink: Pair
        public let chip: Pair
        public let chipText: Pair
    }

    /// The web's `PALETTE` values.
    public var hue: Hue {
        func hue(_ values: [String]) -> Hue {
            Hue(
                swatch: Pair(light: values[0], dark: values[1]), ink: Pair(light: values[2], dark: values[3]),
                chip: Pair(light: values[4], dark: values[5]), chipText: Pair(light: values[6], dark: values[7]))
        }
        switch self {
        case .rose:
            return hue(["#f43f5e", "#fb7185", "#e11d48", "#fb7185", "#ffe4e6", "#4c051999", "#9f1239", "#fda4af"])
        case .orange:
            return hue(["#f97316", "#fb923c", "#ea580c", "#fb923c", "#ffedd5", "#43140799", "#9a3412", "#fdba74"])
        case .amber:
            return hue(["#f59e0b", "#fbbf24", "#d97706", "#fbbf24", "#fef3c7", "#451a0399", "#78350f", "#fcd34d"])
        case .lime:
            return hue(["#84cc16", "#a3e635", "#4d7c0f", "#a3e635", "#ecfccb", "#1a2e0599", "#365314", "#bef264"])
        case .emerald:
            return hue(["#10b981", "#34d399", "#059669", "#34d399", "#d1fae5", "#022c2299", "#065f46", "#6ee7b7"])
        case .teal:
            return hue(["#14b8a6", "#2dd4bf", "#0d9488", "#2dd4bf", "#ccfbf1", "#042f2e99", "#115e59", "#5eead4"])
        case .sky:
            return hue(["#0ea5e9", "#38bdf8", "#0284c7", "#38bdf8", "#e0f2fe", "#082f4999", "#075985", "#7dd3fc"])
        case .blue:
            return hue(["#3b82f6", "#60a5fa", "#2563eb", "#60a5fa", "#dbeafe", "#17255499", "#1e40af", "#93c5fd"])
        case .indigo:
            return hue(["#6366f1", "#818cf8", "#4f46e5", "#818cf8", "#e0e7ff", "#1e1b4b99", "#3730a3", "#a5b4fc"])
        case .violet:
            return hue(["#8b5cf6", "#a78bfa", "#7c3aed", "#a78bfa", "#ede9fe", "#2e106599", "#5b21b6", "#c4b5fd"])
        case .fuchsia:
            return hue(["#d946ef", "#e879f9", "#c026d3", "#e879f9", "#fae8ff", "#4a044e99", "#86198f", "#f0abfc"])
        case .slate:
            return hue(["#94a3b8", "#64748b", "#64748b", "#94a3b8", "#f1f5f9", "#1e293b", "#334155", "#cbd5e1"])
        }
    }

    /// Colours a name can be given without a choice: every hue but the grey.
    static let derivable: [TodoColor] = allCases.filter { $0 != .slate }

    /// Hex values that name a palette colour: a stored colour may hold one instead of its key.
    static let legacyHex: [String: TodoColor] = [
        "#f43f5e": .rose, "#f59e0b": .amber, "#10b981": .emerald, "#0ea5e9": .sky, "#8b5cf6": .violet,
        "#ec4899": .fuchsia, "#64748b": .slate,
    ]

    /// A stored colour as a palette key; anything unknown reads as nothing stored.
    public static func stored(_ value: String?) -> TodoColor? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        return TodoColor(rawValue: text) ?? legacyHex[text]
    }

    /// FNV-1a over the UTF-16 code units, as the browser indexes a string.
    public static func nameHash(_ text: String) -> UInt32 {
        var value: UInt32 = 0x811c_9dc5
        for unit in text.utf16 {
            value ^= UInt32(unit)
            value = value &* 0x0100_0193
        }
        return value
    }

    /// The colour a name gets while nobody chose one: from its trimmed, lower-cased text.
    public static func derived(_ name: String) -> TodoColor {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return derivable[Int(nameHash(key) % UInt32(derivable.count))]
    }
}

/// A symbol a view or a list can carry: the stored key (`View.icon`, `TodoList.icon`), mapped to
/// a symbol of the phone's own. A key this build does not know reads as nothing stored.
public enum TodoIcon: String, CaseIterable, Sendable {
    case sun, calendar, layers, clock, inbox, done, filter, hash, list, user, users, bug, star, flag, target, zap
    case heart, home, work, laptop, code, mail, phone, cart, food, coffee, money, repair, package, gift, book
    case learn, idea, music, film, game, art, sport, bike, mountain, travel, car, health, plant, nature, pet
    case baby, rocket, folder, archive

    public static func stored(_ value: String?) -> TodoIcon? { value.flatMap(TodoIcon.init(rawValue:)) }

    /// The SF Symbol drawn for it.
    public var systemImage: String {
        switch self {
        case .sun: "sun.max"
        case .calendar: "calendar"
        case .layers: "square.3.layers.3d"
        case .clock: "clock"
        case .inbox: "tray"
        case .done: "checkmark.circle"
        case .filter: "line.3.horizontal.decrease"
        case .hash: "number"
        case .list: "checklist"
        case .user: "person"
        case .users: "person.2"
        case .bug: "ladybug"
        case .star: "star"
        case .flag: "flag"
        case .target: "target"
        case .zap: "bolt"
        case .heart: "heart"
        case .home: "house"
        case .work: "briefcase"
        case .laptop: "laptopcomputer"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .mail: "envelope"
        case .phone: "phone"
        case .cart: "cart"
        case .food: "fork.knife"
        case .coffee: "cup.and.saucer"
        case .money: "wallet.bifold"
        case .repair: "wrench.and.screwdriver"
        case .package: "shippingbox"
        case .gift: "gift"
        case .book: "book"
        case .learn: "graduationcap"
        case .idea: "lightbulb"
        case .music: "music.note"
        case .film: "film"
        case .game: "gamecontroller"
        case .art: "paintpalette"
        case .sport: "dumbbell"
        case .bike: "bicycle"
        case .mountain: "mountain.2"
        case .travel: "airplane"
        case .car: "car"
        case .health: "stethoscope"
        case .plant: "leaf"
        case .nature: "tree"
        case .pet: "pawprint"
        case .baby: "figure.and.child.holdinghands"
        case .rocket: "paperplane"
        case .folder: "folder"
        case .archive: "archivebox"
        }
    }
}

/// Who a tag, view or list is at a glance: its colour and, for views and lists, its symbol.
public struct TodoIdentity: Equatable, Sendable {
    public let icon: TodoIcon
    public let color: TodoColor

    public init(icon: TodoIcon, color: TodoColor) {
        self.icon = icon
        self.color = color
    }

    /// Per tag name (lower-cased): the colour someone chose. A name in several lists takes the
    /// first choice in id order, so every client picks the same one.
    public static func chosenTagColors(_ tags: [TodoTag]) -> [String: TodoColor] {
        var chosen: [String: TodoColor] = [:]
        for tag in tags.sorted(by: { $0.id < $1.id }) {
            guard let color = TodoColor.stored(tag.color) else { continue }
            let name = tag.name.lowercased()
            if chosen[name] == nil { chosen[name] = color }
        }
        return chosen
    }

    /// A tag's colour: the one chosen for it; else its nearest parent's (`home/garden` wears
    /// `home`'s); else the colour its top name derives, so a family shares one colour.
    public static func tagColor(_ name: String, chosen: [String: TodoColor]) -> TodoColor {
        let parts = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var depth = parts.count
        while depth > 0 {
            if let found = chosen[parts[0..<depth].joined(separator: "/")] { return found }
            depth -= 1
        }
        return TodoColor.derived(parts.first ?? "")
    }

    static let builtins: [String: TodoIdentity] = [
        "today": TodoIdentity(icon: .sun, color: .amber), "upcoming": TodoIdentity(icon: .calendar, color: .rose),
        "all": TodoIdentity(icon: .layers, color: .sky), "chrono": TodoIdentity(icon: .clock, color: .slate),
        "inbox": TodoIdentity(icon: .inbox, color: .blue), "logbook": TodoIdentity(icon: .done, color: .emerald),
    ]

    /// The one tag a query is, when it is exactly `tag:<name>` (or `tag:"<name>"`).
    public static func tagOfQuery(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("tag:") else { return nil }
        let rest = String(text.dropFirst(4))
        if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
            let inner = String(rest.dropFirst().dropLast())
            if !inner.isEmpty, !inner.contains("\"") { return inner }
        }
        guard !rest.isEmpty, !rest.contains(where: \.isWhitespace) else { return nil }
        return rest
    }

    /// A view's colour as stored: `display.color`.
    static func viewStoredColor(_ display: PaiJSONValue) -> TodoColor? {
        guard case .object(let fields) = display, case .string(let value) = fields["color"] else { return nil }
        return TodoColor.stored(value)
    }

    /// A view's symbol and colour: what the person chose; else a built-in's own; else, for a view
    /// that is exactly one tag, that tag's colour and a hash; else a filter in its name's colour.
    public static func of(view: TodoView, tagColor: (String) -> TodoColor) -> TodoIdentity {
        let builtin = view.builtin.flatMap { builtins[$0] }
        let tag = builtin == nil ? tagOfQuery(view.query) : nil
        let icon = TodoIcon.stored(view.icon) ?? builtin?.icon ?? (tag == nil ? .filter : .hash)
        let color =
            viewStoredColor(view.display) ?? builtin?.color ?? (tag.map(tagColor) ?? TodoColor.derived(view.name))
        return TodoIdentity(icon: icon, color: color)
    }

    /// A list's symbol and colour: what was stored on it, else by its kind and its name.
    public static func of(list: TodoList) -> TodoIdentity {
        let byKind: TodoIcon =
            switch list.kind {
            case .personal: .user
            case .issues: .bug
            case .shared, .unrecognized: .users
            }
        return TodoIdentity(
            icon: TodoIcon.stored(list.icon) ?? byKind,
            color: TodoColor.stored(list.color) ?? TodoColor.derived(list.name))
    }
}

/// How a horizon is shown: its name and its mark, a ring in its colour that warms as a todo comes
/// closer; `whenever` is dashed and `now` carries a dot, so the four differ by shape too.
public struct TodoHorizonMark: Equatable, Sendable {
    public let label: String
    public let color: TodoColor
    public let dashed: Bool
    public let dot: Bool

    public static func of(_ horizon: TodoHorizon) -> TodoHorizonMark {
        switch horizon {
        case .now: TodoHorizonMark(label: "Now", color: .orange, dashed: false, dot: true)
        case .week: TodoHorizonMark(label: "This week", color: .amber, dashed: false, dot: false)
        case .soon: TodoHorizonMark(label: "Soon", color: .teal, dashed: false, dot: false)
        case .whenever, .unrecognized: TodoHorizonMark(label: "Whenever", color: .slate, dashed: true, dot: false)
        }
    }
}
