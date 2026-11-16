import Foundation

extension PaiApiClient {

    // MARK: Alarm

    public func listAlarms() async throws -> AlarmListResponse {
        try await send(path: "/api/alarm")
    }

    public func createAlarm(_ alarm: AlarmCreate) async throws -> Alarm {
        try await send(path: "/api/alarm", method: "POST", body: try Self.jsonBody(alarm))
    }

    public func deleteAlarm(id: String) async throws {
        try await sendDiscardingResponse(path: "/api/alarm/\(id)", method: "DELETE", contentType: nil)
    }

    /// Idempotent: the server answers 204 for an alarm that is already gone.
    public func dismissAlarm(id: String) async throws {
        try await sendDiscardingResponse(path: "/api/alarm/\(id)/dismiss", method: "POST", contentType: nil)
    }

    /// Dismisses every alarm of the signed-in person that is ringing.
    public func dismissRingingAlarms() async throws {
        try await sendDiscardingResponse(path: "/api/alarm/dismiss", method: "POST", contentType: nil)
    }

    // MARK: Watch keys

    public func listWatchKeys() async throws -> [WatchKey] {
        try await send(path: "/api/watch-keys")
    }

    public func createWatchKey(name: String) async throws -> WatchKeyCreated {
        struct Body: Encodable { let name: String }
        return try await send(path: "/api/watch-keys", method: "POST", body: try Self.jsonBody(Body(name: name)))
    }

    public func revokeWatchKey(id: String) async throws {
        try await sendDiscardingResponse(path: "/api/watch-keys/\(id)", method: "DELETE", contentType: nil)
    }
}
