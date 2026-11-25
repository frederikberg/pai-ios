import Foundation

/// Which half of Settings a category belongs to.
public enum SettingsArea: Sendable, Equatable {
    /// What affects only the person; everyone has it.
    case yours
    /// What changes the instance, costs money, or concerns other people; the owner's.
    case administration
}

/// Whose a card of settings is, drawn as a suffix of its header so "is this global?" has one answer
/// everywhere.
public enum SettingsScope: Sendable, Equatable {
    /// The person's account: the same on every device.
    case synced
    /// This iPhone only.
    case thisDevice
    /// A setting of the instance that changes what guests get; administration only.
    case everyone

    public var label: String {
        switch self {
        case .synced: "Synced"
        case .thisDevice: "This iPhone"
        case .everyone: "All users"
        }
    }
}

/// The pages of Settings, in the order the list shows them. A new page is one case here and a
/// screen in the app; the list, its sections and who sees which are drawn from this.
public enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    // Yours
    case microphone, notifications, voices, appearance, location, devices, history, thisPhone
    // Administration
    case system, alerts, mail, providers, models, integrations, voiceSound, agents, people, diagnostics

    public var id: String { rawValue }

    public var area: SettingsArea {
        switch self {
        case .microphone, .notifications, .voices, .appearance, .location, .devices, .history, .thisPhone: .yours
        case .system, .alerts, .mail, .providers, .models, .integrations, .voiceSound, .agents, .people,
            .diagnostics:
            .administration
        }
    }

    public var title: String {
        switch self {
        case .microphone: "Microphone & dictation"
        case .notifications: "Notifications"
        case .voices: "Voices"
        case .appearance: "Appearance"
        case .location: "Location"
        case .devices: "Devices & sign-ins"
        case .history: "History"
        case .thisPhone: "This iPhone"
        case .system: "System"
        case .alerts: "Alerts & routing"
        case .mail: "Mail server"
        case .providers: "Providers & keys"
        case .models: "Models"
        case .integrations: "Integrations"
        case .voiceSound: "Voice & sound"
        case .agents: "Agents"
        case .people: "People & devices"
        case .diagnostics: "Diagnostics"
        }
    }

    public var summary: String {
        switch self {
        case .microphone: "How this iPhone listens, and how what you dictate is transcribed."
        case .notifications: "What reaches you, and where. Everything is always kept in Notifications."
        case .voices: "How replies, calls and Computer sound to you."
        case .appearance: "How PAI looks on this iPhone."
        case .location: "Where the weather answers for, and the iPhone that keeps it current."
        case .devices: "The phones and browsers signed in as you, and the keys your watch reaches your alarms with."
        case .history: "What this iPhone remembers of what you dictated and sent."
        case .thisPhone: "Notes kept for offline use, and what the app captured when it last crashed."
        case .system: "What needs attention on the machine PAI runs on."
        case .alerts: "Who hears about each kind of alert, and which agent task picks them up."
        case .mail: "The account every mail from PAI goes out through."
        case .providers: "The services PAI calls, and the keys it calls them with."
        case .models: "Which model answers each part of PAI."
        case .integrations: "Services PAI reaches on its own, so an agent can use them unattended."
        case .voiceSound: "The voice everyone starts with, and what is kept for diagnosing."
        case .agents: "What every scheduled agent is told about your situation."
        case .people: "Every person's sign-ins and watch keys, and the machines that reach PAI."
        case .diagnostics: "What the speech engines heard, for finding out why something was misheard."
        }
    }

    public var systemImage: String {
        switch self {
        case .microphone: "mic.fill"
        case .notifications: "bell.fill"
        case .voices: "waveform"
        case .appearance: "paintpalette.fill"
        case .location: "location.fill"
        case .devices: "iphone"
        case .history: "clock.arrow.circlepath"
        case .thisPhone: "iphone.gen3"
        case .system: "server.rack"
        case .alerts: "bell.badge.fill"
        case .mail: "envelope.fill"
        case .providers: "key.fill"
        case .models: "cpu"
        case .integrations: "puzzlepiece.extension.fill"
        case .voiceSound: "speaker.wave.2.fill"
        case .agents: "person.crop.circle.badge.clock"
        case .people: "person.2.fill"
        case .diagnostics: "stethoscope"
        }
    }

    /// The icon square's colour as `RRGGBB`; the administration pages share one slate.
    public var tintHex: UInt32 {
        switch self {
        case .microphone: 0xBE185D
        case .notifications: 0xDC2626
        case .voices: 0x7C3AED
        case .appearance, .history, .thisPhone: 0x475569
        case .location: 0x0284C7
        case .devices: 0x059669
        case .system, .alerts, .mail, .providers, .models, .integrations, .voiceSound, .agents, .people,
            .diagnostics:
            0x334155
        }
    }

    /// Whether this person has the page. A guest has the person's own pages and none of the
    /// administration; until the role is known only the pages that read nothing from the server.
    public func isAvailable(to capabilities: Capabilities) -> Bool {
        switch area {
        case .administration:
            return capabilities.canAdminister
        case .yours:
            switch self {
            case .notifications: return capabilities.canRegisterPush
            case .voices, .devices: return capabilities.canOpenPersonSettings
            case .location: return capabilities.canOpenWeather
            case .microphone, .appearance, .history, .thisPhone: return true
            default: return false
            }
        }
    }

    /// The short value the list draws on the right of a row, `nil` for none.
    public func value(theme: AppTheme, sleepWindow: SleepWindow?, openAlerts: Int?) -> String? {
        switch self {
        case .notifications: sleepWindow.map { "Sleep \($0.label)" }
        case .appearance: theme == .system ? "Auto" : theme.rawValue.capitalized
        case .system: openAlerts.flatMap { $0 > 0 ? "\($0) open" : nil }
        default: nil
        }
    }

    /// The pages of one half that this person has, in list order.
    public static func listed(in area: SettingsArea, for capabilities: Capabilities) -> [SettingsCategory] {
        allCases.filter { $0.area == area && $0.isAvailable(to: capabilities) }
    }
}
