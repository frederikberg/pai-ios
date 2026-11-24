import Foundation
import Observation

public protocol AlarmApiClient: Sendable {
    func listAlarms() async throws -> AlarmListResponse
    func createAlarm(_ alarm: AlarmCreate) async throws -> Alarm
    func deleteAlarm(id: String) async throws
    func dismissAlarm(id: String) async throws
    func dismissRingingAlarms() async throws
}

extension PaiApiClient: AlarmApiClient {}

/// The Alarm app's state: the armed alarms, the ones ringing now, and the actions on them. The
/// server owns every state change; this store re-reads after each action so the screen shows the
/// server's answer, and the screen keeps it fresh with ``poll(every:)`` while it is visible.
@MainActor
@Observable
public final class AlarmStore {
    public private(set) var alarms: [Alarm] = []
    public private(set) var ringing: [RingingAlarm] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    private let api: AlarmApiClient

    public init(api: AlarmApiClient) {
        self.api = api
    }

    public func load() async {
        defer { isLoading = false }
        do {
            let response = try await api.listAlarms()
            alarms = response.alarms
            ringing = response.ringing
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the alarms"
        }
    }

    /// Re-reads until the calling task is cancelled. The first read happens at once.
    public func poll(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: interval)
        }
    }

    /// Arms an alarm for the next `hour:minute`; an empty `name` leaves the server's default.
    public func add(
        hour: Int, minute: Int, name: String, now: Date = Date(), calendar: Calendar = .current
    ) async -> Bool {
        guard let fireAt = AlarmTime.nextOccurrence(hour: hour, minute: minute, after: now, calendar: calendar)
        else {
            errorMessage = "That time does not exist today"
            return false
        }
        return await create(fireAt: fireAt, name: name)
    }

    /// Arms an alarm for `now` plus the given duration, fixed here at Save rather than by the
    /// server so it counts from the moment the person pressed it.
    public func add(
        hours: Int, minutes: Int, seconds: Int, name: String, now: Date = Date()
    ) async -> Bool {
        guard
            let fireAt = AlarmTime.relativeFireDate(hours: hours, minutes: minutes, seconds: seconds, after: now)
        else {
            errorMessage = "Set a time above zero"
            return false
        }
        return await create(fireAt: fireAt, name: name)
    }

    private func create(fireAt: Date, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await api.createAlarm(
                AlarmCreate(fireAt: AlarmTime.wireString(fireAt), name: trimmed.isEmpty ? nil : trimmed))
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not save the alarm"
            return false
        }
        await load()
        return true
    }

    public func delete(_ alarm: Alarm) async {
        await act("Could not delete the alarm") { try await $0.deleteAlarm(id: alarm.id) }
    }

    public func dismiss(_ ringing: RingingAlarm) async {
        await act("Could not dismiss the alarm") { try await $0.dismissAlarm(id: ringing.id) }
    }

    public func dismissAll() async {
        await act("Could not dismiss the alarms") { try await $0.dismissRingingAlarms() }
    }

    private func act(_ failure: String, _ call: (AlarmApiClient) async throws -> Void) async {
        do {
            try await call(api)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? failure
        }
        await load()
    }
}
