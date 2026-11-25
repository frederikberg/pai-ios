/// What the signed-in person may reach, derived from `/api/me`.
///
/// The backend refuses a route a guest may not use with a 403, so every screen or startup call
/// that would reach one asks here first instead of sending the request and handling the refusal.
/// Each question is named for the thing it admits; the role is never compared at a call site.
///
/// The questions mirror pai-cloud's route gates (owner-only routes call `require_owner`); the
/// web UI's `ownerOnly` apps are the same list. Until `/api/me` has answered, and for a role this
/// build does not know, every owner-only question is `false`: withholding a screen for a moment
/// costs less than a request the server refuses.
public struct Capabilities: Sendable, Equatable {
    /// `nil` until `/api/me` has answered.
    public let role: UserRole?

    public init(role: UserRole?) {
        self.role = role
    }

    public init(me: MeResponse?) {
        self.init(role: me?.role)
    }

    public static let unknown = Capabilities(role: nil)

    /// Whether `/api/me` has answered; what startup waits for before it sends owner-only calls.
    public var isKnown: Bool { role != nil }

    private var isOwner: Bool { role == .owner }

    /// Any signed-in person the backend knows a role for: the owner and a guest. Per-person
    /// routes (a device token, the alarms, watch keys) are keyed by the caller's own user.
    private var isPerson: Bool { role == .owner || role == .guest }

    public var canOpenNotes: Bool { isOwner }
    public var canOpenArc: Bool { isOwner }
    public var canOpenScheduler: Bool { isOwner }
    public var canOpenCanteen: Bool { isOwner }
    public var canOpenDecisions: Bool { isOwner }
    public var canOpenBrowser: Bool { isOwner }
    /// The Me app and its self-report routes: owner-only, absent from every guest namespace.
    public var canOpenMe: Bool { isOwner }
    /// Reminders (the Scheduler's list, the feed's reminder rows): owner-only, and a guest's feed
    /// never holds one.
    public var canOpenReminders: Bool { isOwner }
    /// The location history, the named places and a day's stays: owner-only. A guest's phone still
    /// sends its latest position for the weather, but nothing is kept and no place is watched.
    public var canReadLocationHistory: Bool { isOwner }

    /// The write-only secrets' presence read (`GET /api/settings/secrets`).
    public var canReadSecrets: Bool { isOwner }

    /// `POST /api/devices/register`: a device token belongs to the signed-in person, a guest's
    /// included.
    public var canRegisterPush: Bool { isPerson }

    /// The Alarm app and the watch keys: person routes, open to a guest.
    public var canOpenAlarm: Bool { isPerson }

    /// The Weather app and the location it is answered for: person routes, open to a guest.
    public var canOpenWeather: Bool { isPerson }

    /// The settings that belong to a person (their registry values, their sign-ins and devices):
    /// the owner and a guest have them.
    public var canOpenPersonSettings: Bool { isPerson }

    /// The Administration side of Settings: instance settings, keys and everyone's devices.
    public var canAdminister: Bool { isOwner }
}
