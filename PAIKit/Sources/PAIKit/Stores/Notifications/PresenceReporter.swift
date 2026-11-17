import Foundation

/// Tells the server whether this app is in use, so nothing is pushed to any of the person's
/// devices while they are already looking at PAI. In use means the app is in the foreground:
/// ``setActive(_:)`` follows the scene phase, and while active the report is repeated every
/// ``beat`` because the server forgets one after 75 s.
@MainActor
public final class PresenceReporter {
    public static let beat: Duration = .seconds(30)

    private let report: @MainActor (Bool) async -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var loop: Task<Void, Never>?

    /// `report` sends one state; a failed send is simply repeated by the next beat.
    public init(
        report: @escaping @MainActor (Bool) async -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.report = report
        self.sleep = sleep
    }

    public func setActive(_ active: Bool) {
        loop?.cancel()
        loop = nil
        guard active else {
            Task { await report(false) }
            return
        }
        loop = Task { [report, sleep] in
            while !Task.isCancelled {
                await report(true)
                do { try await sleep(Self.beat) } catch { return }
            }
        }
    }

    /// The id this install reports under: minted once and kept, so the server counts one client
    /// per phone however often the app starts.
    public static func clientId(in defaults: UserDefaults = .standard) -> String {
        let key = "presenceClientId"
        if let stored = defaults.string(forKey: key) { return stored }
        let minted = "ios-\(UUID().uuidString)"
        defaults.set(minted, forKey: key)
        return minted
    }
}
