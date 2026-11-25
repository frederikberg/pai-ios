import Foundation
import Observation

/// What `ComputerModelStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol ComputerModelApiClient: Sendable {
    func getVoiceSettings() async throws -> SpokenVoiceSettings
    func updateComputerModel(_ update: ComputerModelUpdate) async throws -> SpokenVoiceSettings
}

extension PaiApiClient: ComputerModelApiClient {}

/// Which Claude model and effort Computer acts through, and the choices the backend offers for
/// its turn-taking presets. One backend setting every client reads; saved on each pick. An empty
/// choice is "the backend's default" and goes out as `null`.
@MainActor
@Observable
public final class ComputerModelStore {
    /// What the server holds. `nil` until `load()` succeeds.
    public private(set) var loaded: SpokenVoiceSettings?
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    public private(set) var isSaving = false

    private let api: any ComputerModelApiClient

    public init(api: any ComputerModelApiClient) {
        self.api = api
    }

    /// `nil` from a backend that predates the Computer settings.
    public var choices: ComputerChoices? { loaded?.computerChoices }
    /// Empty is the default.
    public var model: String { loaded?.computerClaudeModel ?? "" }
    public var effort: String { loaded?.computerClaudeEffort ?? "" }

    public func load() async {
        do {
            loaded = try await api.getVoiceSettings()
            loadError = nil
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not load Computer's model"
        }
    }

    /// Choosing a model keeps the effort when the new model accepts it and puts back the default
    /// when it does not, since the backend refuses the pair otherwise.
    public func choose(model: String) async {
        let keepsEffort = effort.isEmpty || (choices?.efforts(forModel: model).contains(effort) ?? false)
        await save(
            ComputerModelUpdate(
                model: model.isEmpty ? nil : model, effort: keepsEffort && !effort.isEmpty ? effort : nil))
    }

    public func choose(effort: String) async {
        await save(ComputerModelUpdate(model: model.isEmpty ? nil : model, effort: effort.isEmpty ? nil : effort))
    }

    private func save(_ update: ComputerModelUpdate) async {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            loaded = try await api.updateComputerModel(update)
        } catch {
            saveError = (error as? PaiError)?.userMessage ?? "Could not save Computer's model"
        }
    }
}
