import Foundation
import Observation

/// What `ComputerChoicesStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol ComputerChoicesApiClient: Sendable {
    func getVoiceSettings() async throws -> SpokenVoiceSettings
}

extension PaiApiClient: ComputerChoicesApiClient {}

/// What the backend offers for Computer's turn-taking presets, for the sentence under the preset
/// picker. Read through the older voice route, which is the one place those numbers are served.
@MainActor
@Observable
public final class ComputerChoicesStore {
    /// `nil` until `load()` succeeds, and from a backend that predates the Computer settings.
    public private(set) var choices: ComputerChoices?

    private let api: any ComputerChoicesApiClient

    public init(api: any ComputerChoicesApiClient) {
        self.api = api
    }

    public func load() async {
        choices = (try? await api.getVoiceSettings())?.computerChoices ?? choices
    }
}
