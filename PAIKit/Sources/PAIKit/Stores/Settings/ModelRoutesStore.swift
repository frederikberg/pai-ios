import Foundation
import Observation

/// What `ModelRoutesStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol ModelRoutesApiClient: Sendable {
    func listModelFeatures() async throws -> [ModelFeature]
    func putModelRoute(feature: String, _ update: ModelRouteUpdate) async throws -> ModelFeature
}

extension PaiApiClient: ModelRoutesApiClient {}

/// A route being edited: the default step and, where the feature allows one, a fallback. Moving to
/// another provider or model puts back whatever the new choice does not accept, so a pair the
/// server would refuse is never offered.
public struct ModelRouteDraft: Equatable, Sendable {
    public var defaultStep: ModelStep
    public var fallbackStep: ModelStep?
    public let choices: ModelChoices
    public let fallbackChoices: ModelChoices?

    public init(feature: ModelFeature) {
        defaultStep = feature.default
        fallbackStep = feature.fallback
        choices = feature.choices
        fallbackChoices = feature.fallbackAllowed ? feature.fallbackChoices : nil
    }

    public var offersFallback: Bool { fallbackChoices != nil }

    public func providers(forFallback: Bool) -> [String] {
        (forFallback ? fallbackChoices ?? [:] : choices).keys.sorted()
    }

    public func models(provider: String, forFallback: Bool) -> [String] {
        ((forFallback ? fallbackChoices ?? [:] : choices)[provider] ?? [:]).keys.sorted()
    }

    /// The efforts a model accepts, `nil` standing for "none". Empty when the model sends no effort.
    public func efforts(provider: String, model: String, forFallback: Bool) -> [String?] {
        ((forFallback ? fallbackChoices ?? [:] : choices)[provider] ?? [:])[model] ?? []
    }

    public mutating func chooseProvider(_ provider: String, forFallback: Bool) {
        let first = models(provider: provider, forFallback: forFallback).first ?? ""
        put(
            fitted(ModelStep(provider: provider, model: first, effort: nil), forFallback: forFallback),
            forFallback: forFallback)
    }

    public mutating func chooseModel(_ model: String, forFallback: Bool) {
        let step = forFallback ? fallbackStep : defaultStep
        guard let step else { return }
        put(fitted(ModelStep(provider: step.provider, model: model, effort: step.effort), forFallback: forFallback), forFallback: forFallback)
    }

    public mutating func chooseEffort(_ effort: String?, forFallback: Bool) {
        if forFallback { fallbackStep?.effort = effort } else { defaultStep.effort = effort }
    }

    /// Adds a fallback starting from the first provider and model on offer, or removes it.
    public mutating func setFallback(enabled: Bool) {
        guard offersFallback else { return }
        guard enabled else {
            fallbackStep = nil
            return
        }
        guard fallbackStep == nil, let provider = providers(forFallback: true).first else { return }
        chooseProvider(provider, forFallback: true)
    }

    public var update: ModelRouteUpdate { ModelRouteUpdate(default: defaultStep, fallback: fallbackStep) }

    /// The step with an effort its model accepts: the one it had when still accepted, else the
    /// model's first.
    private func fitted(_ step: ModelStep, forFallback: Bool) -> ModelStep {
        let accepted = efforts(provider: step.provider, model: step.model, forFallback: forFallback)
        var next = step
        if accepted.isEmpty { next.effort = nil } else if !accepted.contains(where: { $0 == step.effort }) {
            next.effort = accepted.first ?? nil
        }
        return next
    }

    private mutating func put(_ step: ModelStep, forFallback: Bool) {
        if forFallback { fallbackStep = step } else { defaultStep = step }
    }
}

/// Which model answers each part of PAI, and the provider that takes over when it cannot: one row
/// per feature, edited a feature at a time.
@MainActor
@Observable
public final class ModelRoutesStore {
    /// `nil` until the first read succeeds.
    public private(set) var features: [ModelFeature]?
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    public private(set) var isSaving = false

    private let api: any ModelRoutesApiClient

    public init(api: any ModelRoutesApiClient) {
        self.api = api
    }

    public func load() async {
        do {
            features = try await api.listModelFeatures()
            loadError = nil
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not load the models"
        }
    }

    /// Writes one feature's route and replaces its row with the server's answer. Returns whether
    /// it was taken; a refusal's reason is in `saveError`.
    @discardableResult
    public func save(_ feature: ModelFeature, _ update: ModelRouteUpdate) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let saved = try await api.putModelRoute(feature: feature.id, update)
            features = features?.map { $0.id == saved.id ? saved : $0 }
            return true
        } catch {
            saveError = (error as? PaiError)?.userMessage ?? "Could not save the route"
            return false
        }
    }

    public func clearSaveError() { saveError = nil }

    /// The features of one group, in the order the server lists them.
    public func features(inGroup group: String) -> [ModelFeature] {
        (features ?? []).filter { $0.group == group }
    }
}
