import Foundation

extension PaiApiClient {

    // MARK: Weather and location

    public func getWeather() async throws -> WeatherResponse {
        try await send(path: "/api/weather")
    }

    /// `GET /api/weather/radar.png` — the radar about 30 minutes ahead, drawn by the server;
    /// nil when it has none (no radar at this place).
    public func getWeatherRadarPicture(size: Int) async throws -> Data? {
        let (status, data) = try await sendPassingThrough(
            path: "/api/weather/radar.png", method: "GET",
            query: [URLQueryItem(name: "size", value: String(size))], contentType: nil, passthrough: [404])
        return status == 404 ? nil : data
    }

    /// Replaces the stored location of the signed-in person; the server answers 204.
    public func postLocation(_ report: LocationReport) async throws {
        try await sendDiscardingResponse(path: "/api/location", method: "POST", body: try Self.jsonBody(report))
    }
}
