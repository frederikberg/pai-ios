import Foundation
import Observation

public protocol WeatherApiClient: Sendable {
    func getWeather() async throws -> WeatherResponse
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

    private let api: WeatherApiClient

    public init(api: WeatherApiClient) {
        self.api = api
    }

    public func load() async {
        defer { isLoading = false }
        do {
            weather = try await api.getWeather()
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the weather"
        }
    }
}
