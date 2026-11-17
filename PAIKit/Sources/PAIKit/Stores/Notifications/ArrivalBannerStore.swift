import Foundation
import Observation

/// One notification arriving while the app is open, as the small banner at the top shows it.
public struct ArrivalBanner: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
}

/// The in-app counterpart of a push: while the app is in use nothing is pushed
/// (docs/architecture/notifications.md in pai-cloud), so an arrival is shown here instead, for
/// ``shownFor`` and then gone. A newer arrival replaces the one on screen.
@Observable
@MainActor
public final class ArrivalBannerStore {
    public static let shownFor: Duration = .milliseconds(2500)

    public private(set) var current: ArrivalBanner?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var hide: Task<Void, Never>?

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Shows `notification` unless it was recorded already read, which is meant to reach nobody.
    public func show(_ notification: PaiNotification) {
        guard notification.readAt == nil else { return }
        let title = notification.runSlug.map { "\($0) · \(notification.title)" } ?? notification.title
        let banner = ArrivalBanner(id: notification.id, title: title)
        current = banner
        hide?.cancel()
        hide = Task { [weak self, sleep] in
            do { try await sleep(Self.shownFor) } catch { return }
            if self?.current == banner { self?.current = nil }
        }
    }

    public func dismiss() {
        hide?.cancel()
        current = nil
    }
}
