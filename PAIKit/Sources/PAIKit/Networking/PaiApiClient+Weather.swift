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

    /// `POST /api/location/points`: up to 500 points. Every point moves the person's latest
    /// position (what the weather reads); the owner's also join the history. A repeated batch
    /// changes nothing, so a retry after a lost answer is harmless.
    public func postLocationPoints(_ points: [LocationPoint]) async throws -> LocationPointsAnswer {
        try await send(
            path: "/api/location/points", method: "POST",
            body: try Self.jsonBody(LocationPointsRequest(points: points)))
    }

    /// `GET /api/places/monitor` (owner only): the places this phone geofences.
    public func getPlacesMonitor() async throws -> PlacesMonitorAnswer {
        try await send(path: "/api/places/monitor")
    }

    /// `GET /api/location/day` (owner only): one Berlin day, `yyyy-MM-dd`.
    public func getLocationDay(date: String) async throws -> LocationDay {
        try await send(path: "/api/location/day", query: [URLQueryItem(name: "date", value: date)])
    }
}
