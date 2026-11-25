import Foundation
import Observation

public protocol ReminderDetailApiClient: Sendable {
    func getReminder(ref: String) async throws -> Reminder
    func setReminderPaused(ref: String, paused: Bool) async throws -> Reminder
    func resumeReminder(ref: String) async throws -> Reminder
    func deleteReminder(ref: String) async throws
    func testReminder(ref: String, event: ReminderTestEvent?, notify: Bool) async throws -> ReminderTestResult
}

extension PaiApiClient: ReminderDetailApiClient {}

/// One reminder: its detail and the four things done to it. A refusal's text is kept for the
/// screen to show; a reminder the server no longer knows says so instead of an error.
@MainActor
@Observable
public final class ReminderDetailStore {
    public private(set) var reminder: Reminder?
    public private(set) var isLoading = true
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?
    /// Set when the server answered 404: deleted since the list was read.
    public private(set) var isGone = false
    public private(set) var testResult: ReminderTestResult?
    /// Set once a delete went through, so the screen can leave.
    public private(set) var isDeleted = false

    private let id: String
    private let api: ReminderDetailApiClient

    public init(id: String, api: ReminderDetailApiClient) {
        self.id = id
        self.api = api
    }

    public func load() async {
        defer { isLoading = false }
        do {
            reminder = try await api.getReminder(ref: id)
            errorMessage = nil
            isGone = false
        } catch let error as PaiError {
            if error.isNotFound { isGone = true } else { errorMessage = error.userMessage }
        } catch {
            errorMessage = "Could not load the reminder"
        }
    }

    /// A reminder that is checking (armed, or failing and still retrying) can be paused; a paused
    /// or failing one can be armed again. Fired and expired ones are edited by an agent.
    public var canPause: Bool { reminder?.state == .armed || reminder?.state == .failing }
    public var canResume: Bool { reminder?.state == .paused || reminder?.state == .failing }

    public func pause() async {
        await act { try await self.api.setReminderPaused(ref: self.id, paused: true) }
    }

    public func resume() async {
        await act { try await self.api.resumeReminder(ref: self.id) }
    }

    public func delete() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.deleteReminder(ref: id)
            isDeleted = true
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not delete the reminder"
        }
    }

    /// Runs the check once. A place or Home Assistant reminder has no script to run, so it is
    /// given the event that satisfies its trigger; `notify` also sends a test notification.
    public func test(notify: Bool) async {
        guard let reminder, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            testResult = try await api.testReminder(
                ref: id, event: ReminderTestEvent(satisfying: reminder.trigger), notify: notify)
            errorMessage = nil
            if notify { await load() }
        } catch {
            testResult = nil
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not test the reminder"
        }
    }

    public func dismissTestResult() { testResult = nil }

    private func act(_ call: @escaping () async throws -> Reminder) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            reminder = try await call()
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not change the reminder"
        }
    }
}
