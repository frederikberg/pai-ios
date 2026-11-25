import Foundation
import Observation

public protocol LocationDayApiClient: Sendable {
    func getLocationDay(date: String) async throws -> LocationDay
}

extension PaiApiClient: LocationDayApiClient {}

/// The stays of the day picked in Me, read when a day is picked. A day the server cannot answer
/// (an older server, no history yet) shows nothing: the line is an extra, never an error.
@MainActor
@Observable
public final class LocationDayStore {
    public private(set) var day: LocationDay?

    private let api: LocationDayApiClient
    private let capabilities: @MainActor () -> Capabilities
    private var requested: String?

    public init(api: LocationDayApiClient, capabilities: @escaping @MainActor () -> Capabilities) {
        self.api = api
        self.capabilities = capabilities
    }

    /// Reads one day. A newer pick that arrives while this answers wins.
    public func load(date: String) async {
        requested = date
        guard capabilities().canReadLocationHistory else {
            day = nil
            return
        }
        let answer = try? await api.getLocationDay(date: date)
        guard requested == date else { return }
        day = answer
    }
}
