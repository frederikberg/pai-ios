import Foundation

extension PaiApiClient {

    // MARK: Reminders (owner only)

    /// `GET /api/reminders`: every reminder, without scripts or history.
    public func listReminders() async throws -> [Reminder] {
        let answer: ReminderListResponse = try await send(path: "/api/reminders")
        return answer.reminders
    }

    /// `GET /api/reminders/{id|name}`: one reminder with its script, last result and newest events.
    public func getReminder(ref: String) async throws -> Reminder {
        try await send(path: "/api/reminders/\(Self.pathSegment(ref))")
    }

    /// `PATCH /api/reminders/{id|name}` with `{"paused": …}`: pauses or resumes, answering the
    /// detail.
    public func setReminderPaused(ref: String, paused: Bool) async throws -> Reminder {
        struct Body: Encodable { let paused: Bool }
        return try await send(
            path: "/api/reminders/\(Self.pathSegment(ref))", method: "PATCH",
            body: try Self.jsonBody(Body(paused: paused)))
    }

    /// `POST /api/reminders/{id|name}/resume`: arms a paused or failing reminder again.
    public func resumeReminder(ref: String) async throws -> Reminder {
        try await send(path: "/api/reminders/\(Self.pathSegment(ref))/resume", method: "POST")
    }

    /// `DELETE /api/reminders/{id|name}`.
    public func deleteReminder(ref: String) async throws {
        try await sendDiscardingResponse(path: "/api/reminders/\(Self.pathSegment(ref))", method: "DELETE")
    }

    /// `POST /api/reminders/{id|name}/test`: runs the script once without changing the reminder.
    /// `event` is what a place or Home Assistant trigger would be given; `notify` also sends one
    /// notification titled as a test.
    public func testReminder(ref: String, event: ReminderTestEvent?, notify: Bool) async throws -> ReminderTestResult {
        struct Body: Encodable {
            let event: ReminderTestEvent?
            let notify: Bool
        }
        return try await send(
            path: "/api/reminders/\(Self.pathSegment(ref))/test", method: "POST",
            body: try Self.jsonBody(Body(event: event, notify: notify)))
    }

    /// A reminder id or name as one path segment.
    static func pathSegment(_ ref: String) -> String {
        ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? ref
    }
}

/// The event a test of a place or Home Assistant reminder is given: the fields the trigger
/// matches on and nothing else.
public struct ReminderTestEvent: Encodable, Sendable, Equatable {
    public let place: String?
    public let on: String?
    public let entityId: String?
    public let from: String?
    public let to: String?

    enum CodingKeys: String, CodingKey {
        case place, on, from, to
        case entityId = "entity_id"
    }

    public init(
        place: String? = nil, on: String? = nil, entityId: String? = nil, from: String? = nil, to: String? = nil
    ) {
        self.place = place
        self.on = on
        self.entityId = entityId
        self.from = from
        self.to = to
    }

    /// The event that satisfies `trigger`, or nil for a trigger driven by a script alone.
    public init?(satisfying trigger: ReminderTrigger) {
        switch trigger.kind {
        case .place:
            guard let place = trigger.place, let on = trigger.on else { return nil }
            self.init(place: place, on: on)
        case .ha:
            guard let entity = trigger.entityId else { return nil }
            self.init(entityId: entity, from: trigger.from, to: trigger.to)
        case .poll, .listen, .unrecognized:
            return nil
        }
    }
}
