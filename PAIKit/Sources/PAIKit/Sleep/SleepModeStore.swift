import Foundation
import Observation

/// What sleep mode keeps on this phone. Never synced: it belongs to one iPhone, and what the server
/// needs of it is only the window.
public struct SleepModeSettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var window = SleepWindow.standard
    public var pin: SleepPin?
    /// Set by "Wake early": the app is normal until this moment, then the next window applies.
    public var skipUntil: Date?

    public init() {}
}

/// What entering a PIN came to.
public enum SleepPinResult: Equatable, Sendable {
    case accepted
    /// Not the PIN. Three wrong tries in a row make the next wait a second.
    case wrong
    /// Too soon after the third wrong try; try again after `seconds`.
    case wait(seconds: Double)
}

/// Sleep mode: a window in which the session surfaces are put away behind a screen of the other
/// apps. Off until someone enables it; changing or leaving it asks for a PIN.
///
/// `isAsleep` is the one answer to "is it sleep time". The navigation gate, the root screen, the
/// arrival banners and the recording stop all read it, and nothing else computes it. It is a
/// stored value that `refresh()` recomputes, so the owner of the clock (a timer to
/// `nextBoundary`, every return to the front, a time-zone change) is the only place time passes.
///
/// Not main-actor isolated, because ``Router`` is not and asks it on every navigation; the app
/// touches it from the main actor only.
@Observable
public final class SleepModeStore {
    private static let storageKey = "sleepMode"

    public private(set) var settings: SleepModeSettings
    public private(set) var isAsleep = false
    /// The next moment `isAsleep` can change on its own while the app runs, for the timer.
    public private(set) var nextBoundary: Date?

    /// Called once each time sleep time begins, so whatever belongs to the sessions can stop.
    @ObservationIgnored public var onSleepBegan: (() -> Void)?

    @ObservationIgnored private let storage: SettingsKeyValueStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let zone: @Sendable () -> TimeZone
    @ObservationIgnored private let makeSalt: @Sendable () -> String
    @ObservationIgnored private var wrongTries = 0
    @ObservationIgnored private var lockedUntil: Date?

    public init(
        storage: SettingsKeyValueStore, now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        makeSalt: @escaping @Sendable () -> String = { SleepPin.randomSalt() }
    ) {
        self.storage = storage
        self.now = now
        self.zone = zone
        self.makeSalt = makeSalt
        settings = storage.value(forKey: Self.storageKey) ?? SleepModeSettings()
        refresh()
    }

    /// Whether a window is set up at all: enabled, with a PIN.
    public var isEnabled: Bool { settings.isEnabled && settings.pin != nil }

    /// The window as the server is told it: `nil` while sleep mode is off.
    public var window: SleepWindow? { isEnabled ? settings.window : nil }

    /// When "Wake early" ends the current window, or `nil` outside one.
    public var windowEnd: Date? {
        guard isAsleep else { return nil }
        return settings.window.end(ofWindowContaining: now(), in: zone())
    }

    /// What the server is told about this phone's sleep: the window with the zone it is read in,
    /// and the end of a "wake early" that has not ended yet. Nothing while sleep mode is off, which
    /// clears the window there. The server applies the same wall-clock rule, so a phone that is
    /// switched off at 22:00 still gets no push.
    public func deviceChoice() -> DeviceSleepChoice {
        guard let window else { return .none }
        let skip = settings.skipUntil.flatMap { $0 > now() ? IsoTimestamp.utcString(from: $0) : nil }
        return DeviceSleepChoice(
            window: .init(start: window.startText, end: window.endText, tz: zone().identifier), skipUntil: skip)
    }

    /// Recomputes `isAsleep` and the next boundary from the clock. Cheap; call it whenever time
    /// may have moved.
    public func refresh() {
        let moment = now()
        let tz = zone()
        let skipped = settings.skipUntil.map { moment < $0 } ?? false
        let inside = isEnabled && !skipped && settings.window.contains(moment, in: tz)
        let began = inside && !isAsleep
        if inside != isAsleep { isAsleep = inside }
        nextBoundary = isEnabled ? nextChange(after: moment, in: tz) : nil
        if began { onSleepBegan?() }
    }

    private func nextChange(after moment: Date, in tz: TimeZone) -> Date? {
        guard let boundary = settings.window.nextBoundary(after: moment, in: tz) else { return nil }
        if let skip = settings.skipUntil, moment < skip { return min(skip, boundary) }
        return boundary
    }

    // MARK: Guarded changes

    /// Turns sleep mode on with a first window and PIN. Refused for a PIN that is not four to six
    /// digits.
    @discardableResult
    public func enable(window: SleepWindow, pin: String) -> Bool {
        guard SleepPin.isWellFormed(pin) else { return false }
        settings.isEnabled = true
        settings.window = window
        settings.pin = SleepPin(pin: pin, salt: makeSalt())
        settings.skipUntil = nil
        save()
        return true
    }

    /// Checks a PIN. Three wrong tries in a row put a one-second pause before the next is read.
    public func check(_ pin: String) -> SleepPinResult {
        guard let stored = settings.pin else { return .accepted }
        let moment = now()
        if let lockedUntil, moment < lockedUntil {
            return .wait(seconds: lockedUntil.timeIntervalSince(moment))
        }
        if stored.matches(pin) {
            wrongTries = 0
            lockedUntil = nil
            return .accepted
        }
        wrongTries += 1
        if wrongTries % 3 == 0 { lockedUntil = moment.addingTimeInterval(1) }
        return .wrong
    }

    /// Changes the window; needs the PIN.
    public func setWindow(_ window: SleepWindow, pin: String) -> SleepPinResult {
        let result = check(pin)
        guard result == .accepted else { return result }
        settings.window = window
        save()
        return result
    }

    /// Turns sleep mode off; needs the PIN. The PIN is forgotten with it.
    public func disable(pin: String) -> SleepPinResult {
        let result = check(pin)
        guard result == .accepted else { return result }
        settings = SleepModeSettings()
        save()
        return result
    }

    /// Changes the PIN; needs the old one.
    public func changePin(from old: String, to new: String) -> SleepPinResult {
        guard SleepPin.isWellFormed(new) else { return .wrong }
        let result = check(old)
        guard result == .accepted else { return result }
        settings.pin = SleepPin(pin: new, salt: makeSalt())
        save()
        return result
    }

    /// Ends the current window early; needs the PIN. The app is normal until the window's end,
    /// and the next window applies as usual.
    public func wakeEarly(pin: String) -> SleepPinResult {
        let result = check(pin)
        guard result == .accepted else { return result }
        if let end = windowEnd {
            settings.skipUntil = end
            save()
        }
        return result
    }

    private func save() {
        storage.setValue(settings, forKey: Self.storageKey)
        refresh()
    }
}
