import Foundation

extension PaiApiClient {

    // MARK: Weather and location

    public func getWeather() async throws -> WeatherResponse {
        try await send(path: "/api/weather")
    }

    /// Replaces the stored location of the signed-in person; the server answers 204.
    public func postLocation(_ report: LocationReport) async throws {
        try await sendDiscardingResponse(path: "/api/location", method: "POST", body: try Self.jsonBody(report))
    }
}
