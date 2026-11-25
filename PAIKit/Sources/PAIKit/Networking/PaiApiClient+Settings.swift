import Foundation

extension PaiApiClient {

    /// `GET /api/settings` — the registry's schema and the caller's values (and the instance's,
    /// for the owner).
    public func getSettings() async throws -> SettingsResponse {
        try await send(path: "/api/settings")
    }

    /// `PATCH /api/settings/person` — any subset of the caller's keys, every one landing or none;
    /// `null` resets a key that is not nullable. The answer is the person's values.
    public func patchPersonSettings(_ patch: [String: SettingValue]) async throws -> [String: SettingValue] {
        struct Answer: Decodable { let person: [String: SettingValue] }
        let answer: Answer = try await send(
            path: "/api/settings/person", method: "PATCH", body: try Self.jsonBody(patch))
        return answer.person
    }

    /// `PATCH /api/settings/instance` — the owner's. The answer is the instance's values.
    public func patchInstanceSettings(_ patch: [String: SettingValue]) async throws -> [String: SettingValue] {
        struct Answer: Decodable { let instance: [String: SettingValue] }
        let answer: Answer = try await send(
            path: "/api/settings/instance", method: "PATCH", body: try Self.jsonBody(patch))
        return answer.instance
    }
}
