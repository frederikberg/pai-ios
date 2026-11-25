import Foundation
import Observation

public protocol ReminderListApiClient: Sendable {
    func listReminders() async throws -> [Reminder]
}

extension PaiApiClient: ReminderListApiClient {}

/// The owner's reminders as the Scheduler lists them: live ones first, finished ones after.
@MainActor
@Observable
public final class ReminderListStore {
    public private(set) var reminders: [Reminder] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    private let api: ReminderListApiClient

    public init(api: ReminderListApiClient) {
        self.api = api
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            reminders = Self.ordered(try await api.listReminders())
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load reminders"
        }
    }

    /// Reminders that can still fire (armed, failing, paused) lead, each group by name; fired and
    /// expired ones follow. The server's order is by creation, which says nothing a reader wants.
    static func ordered(_ reminders: [Reminder]) -> [Reminder] {
        func finished(_ reminder: Reminder) -> Bool { reminder.state == .fired || reminder.state == .expired }
        let live = reminders.filter { !finished($0) }.sorted { $0.name < $1.name }
        let done = reminders.filter(finished).sorted { $0.name < $1.name }
        return live + done
    }
}
