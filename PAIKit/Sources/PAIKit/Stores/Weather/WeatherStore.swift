import Foundation
import Observation

public protocol WeatherApiClient: Sendable {
    func getWeather() async throws -> WeatherResponse
    func getWeatherRadarPicture(size: Int) async throws -> Data?
}

extension PaiApiClient: WeatherApiClient {}

/// The Weather app's answer. The server computes everything; a failed read keeps the answer on
/// screen and says so, so a glance never shows a blank where rain pants were decided a minute ago.
@MainActor
@Observable
public final class WeatherStore {
    public private(set) var weather: WeatherResponse?
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    /// The radar picture of the current answer (PNG); nil while there is none or it could not load.
    public private(set) var radarPicture: Data?
    /// Edge in pixels the picture is asked for: twice the points it is drawn at.
    public static let radarPictureSize = 720

    private let api: WeatherApiClient

    public init(api: WeatherApiClient) {
        self.api = api
    }

    public func load() async {
        defer { isLoading = false }
        do {
            let answer = try await api.getWeather()
            weather = answer
            errorMessage = nil
            // The picture belongs to this answer: a new answer without one clears the old picture.
            radarPicture =
                answer.radarPictureAt == nil
                ? nil : try? await api.getWeatherRadarPicture(size: Self.radarPictureSize)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the weather"
        }
    }
}
