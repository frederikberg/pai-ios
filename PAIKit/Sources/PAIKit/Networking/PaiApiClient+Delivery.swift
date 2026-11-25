import Foundation

extension PaiApiClient {

    // MARK: Push devices

    /// `GET /api/push/devices` — the caller's own iPhones and browsers.
    public func listPushDevices() async throws -> [PushDevice] {
        let answer: PushDevicesResponse = try await send(path: "/api/push/devices")
        return answer.devices
    }

    /// `PATCH /api/push/devices/{id}` — any subset of what a device chose; 404 for a device that
    /// is not the caller's own.
    public func patchPushDevice(id: String, _ patch: PushDevicePatch) async throws {
        try await sendDiscardingResponse(
            path: "/api/push/devices/\(id)", method: "PATCH", body: try Self.jsonBody(patch))
    }

    // MARK: Connections

    /// `GET /api/settings/connections` — every outside service, owner only.
    public func listConnections() async throws -> [ServiceConnection] {
        let answer: ConnectionsResponse = try await send(path: "/api/settings/connections")
        return answer.connections
    }

    /// `POST /api/settings/connections/{id}/test` — one real call to the service. 409 for one with no
    /// key to test with.
    public func testConnection(id: String) async throws -> ConnectionTestResult {
        try await send(path: "/api/settings/connections/\(id)/test", method: "POST", body: nil, contentType: nil)
    }

    /// `PATCH /api/settings/connections/{id}` — the editable part of an address; `nil` goes back to
    /// the deployment's.
    public func setConnectionAddressPart(id: String, value: String?) async throws -> ServiceConnection {
        struct Body: Encodable {
            let value: String?
            enum CodingKeys: String, CodingKey { case value = "base_url_param" }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(value, forKey: .value)
            }
        }
        let answer: ConnectionResponse = try await send(
            path: "/api/settings/connections/\(id)", method: "PATCH", body: try Self.jsonBody(Body(value: value)))
        return answer.connection
    }

    // MARK: Model routes

    /// `GET /api/settings/models` — every feature with its default, fallback and choices.
    public func listModelFeatures() async throws -> [ModelFeature] {
        let answer: ModelsResponse = try await send(path: "/api/settings/models")
        return answer.features
    }

    /// `PUT /api/settings/models/{feature}` — 400 for a body the catalogue cannot hold, 409 for one
    /// the state refuses (a provider with no key, one whose credit can run out as the last step).
    public func putModelRoute(feature: String, _ update: ModelRouteUpdate) async throws -> ModelFeature {
        let answer: ModelFeatureResponse = try await send(
            path: "/api/settings/models/\(feature)", method: "PUT", body: try Self.jsonBody(update))
        return answer.feature
    }
}
