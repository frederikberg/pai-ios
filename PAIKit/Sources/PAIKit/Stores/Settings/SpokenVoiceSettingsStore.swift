import Foundation
import Observation

/// A text-field-friendly mirror of `SpokenVoiceSettings`' voice-group fields.
///
/// Text fields are plain `String`s — the speeds included, so a half-typed number is a state the
/// input can be in rather than a save that silently rounds it — and key terms are one
/// comma-separated line. The empty-string/`nil`, string/`Double` and line/list translations
/// happen once, at the edges (`init(loaded:)`, `asUpdate()`), rather than at every call site.
/// Same shape as `SmtpSettingsDraft`.
public struct SpokenVoiceSettingsDraft: Sendable, Equatable {
    /// An empty string is "the backend's default", sent as `null`.
    public var computerClaudeModel: String
    public var computerClaudeEffort: String
    public var computerTurnPreset: String
    /// A JSON object laid over the preset; empty is none.
    public var computerTurnTunables: String
    public var callVoiceId: String
    public var callSpeed: String
    public var sttKeyterms: String
    public var sttLanguage: String
    public var sttNoVerbatim: Bool
    /// Whether batch takes are transcribed in the background at all. Kept apart from the seconds
    /// so switching off and on again does not lose the typed value.
    public var sttBatchPauseEnabled: Bool
    public var sttBatchPauseS: String

    public init(loaded: SpokenVoiceSettings) {
        computerClaudeModel = loaded.computerClaudeModel ?? ""
        computerClaudeEffort = loaded.computerClaudeEffort ?? ""
        computerTurnPreset = loaded.computerTurnPreset ?? ""
        computerTurnTunables = Self.formatTunables(loaded.computerTurnTunables)
        callVoiceId = loaded.callVoiceId ?? ""
        callSpeed = Self.format(loaded.callSpeed)
        sttKeyterms = loaded.sttKeyterms.joined(separator: ", ")
        sttLanguage = loaded.sttLanguage ?? ""
        sttNoVerbatim = loaded.sttNoVerbatim
        sttBatchPauseEnabled = loaded.sttBatchPauseS != nil
        sttBatchPauseS = String(loaded.sttBatchPauseS ?? sttBatchPauseDefault)
    }

    /// `nil` when the speed is not a number this can send — the caller gates Save on it rather
    /// than substituting a value, since a typo silently becoming 1.0 is the one outcome that
    /// looks like the setting not working.
    var speed: Double? {
        guard let value = Double(callSpeed), callSpeedRange.contains(value) else { return nil }
        return value
    }

    /// `.some(nil)` when the setting is off, `nil` for seconds that cannot be sent.
    var batchPauseValue: Int?? {
        guard sttBatchPauseEnabled else { return .some(nil) }
        guard let value = Int(sttBatchPauseS.trimmingCharacters(in: .whitespaces)),
            sttBatchPauseRange.contains(value)
        else { return nil }
        return .some(value)
    }

    /// `.some(nil)` for no overrides, `nil` for text that is not a JSON object of tunables. Names
    /// and ranges are the backend's to check; its refusal names the tunable.
    var tunablesValue: [String: ComputerTunableValue]?? {
        let trimmed = computerTurnTunables.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .some(nil) }
        guard let parsed = try? JSONDecoder().decode([String: ComputerTunableValue].self, from: Data(trimmed.utf8))
        else { return nil }
        return .some(parsed.isEmpty ? nil : parsed)
    }

    /// Whether the chosen model accepts the chosen effort — the backend refuses the pair
    /// otherwise. `choices` is the list the backend sent; without it nothing can be checked and
    /// the Computer group is not shown at all.
    func isClaudeChoiceValid(_ choices: ComputerChoices?) -> Bool {
        guard let choices else { return true }
        let model = computerClaudeModel.isEmpty ? choices.defaults.computerClaudeModel : computerClaudeModel
        return computerClaudeEffort.isEmpty || choices.efforts(forModel: model).contains(computerClaudeEffort)
    }

    /// A model change that leaves the effort unacceptable puts the effort back to the default.
    public mutating func chooseModel(_ model: String, choices: ComputerChoices?) {
        computerClaudeModel = model
        if !isClaudeChoiceValid(choices) { computerClaudeEffort = "" }
    }

    var keyterms: [String] {
        sttKeyterms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Why the key terms cannot be saved, or `nil` when they can.
    public var keytermProblem: String? {
        let terms = keyterms
        if terms.count > SttKeytermRules.maxCount { return "At most \(SttKeytermRules.maxCount) key terms" }
        return terms.lazy.compactMap(SttKeytermRules.problem(with:)).first
    }

    func asUpdate() -> SpokenVoiceSettingsUpdate? {
        guard let speed, let batchPause = batchPauseValue,
            let tunables = tunablesValue, keytermProblem == nil
        else { return nil }
        let language = sttLanguage.trimmingCharacters(in: .whitespaces).lowercased()
        return SpokenVoiceSettingsUpdate(
            computerClaudeModel: computerClaudeModel.isEmpty ? nil : computerClaudeModel,
            computerClaudeEffort: computerClaudeEffort.isEmpty ? nil : computerClaudeEffort,
            computerTurnPreset: computerTurnPreset.isEmpty ? nil : computerTurnPreset,
            computerTurnTunables: tunables,
            callVoiceId: callVoiceId.isEmpty ? nil : callVoiceId,
            callSpeed: speed,
            sttKeyterms: keyterms,
            sttLanguage: language.isEmpty ? nil : language,
            sttNoVerbatim: sttNoVerbatim,
            sttBatchPauseS: batchPause
        )
    }

    private static func formatTunables(_ tunables: [String: ComputerTunableValue]?) -> String {
        guard let tunables, !tunables.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(tunables)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Locale-independent, because this string is parsed back with `Double(_:)`, which only ever
    /// accepts a dot. A comma decimal separator would round-trip into a save that cannot parse.
    private static func format(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// The synced voice settings — server-persisted, draft-and-save, the same shape
/// `SmtpSettingsStore` uses. One setting per thing, read by every transport: there is no
/// per-client override, because the backend is the only thing that speaks or transcribes.
@MainActor
@Observable
public final class SpokenVoiceSettingsStore {
    /// What the server holds. `nil` until `load()` completes, or after it fails — which is how a
    /// view tells "not loaded yet" from "loaded and clean".
    public private(set) var loaded: SpokenVoiceSettings?
    public var draft: SpokenVoiceSettingsDraft?

    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var loadError: String?
    public private(set) var saveError: String?

    private let apiClient: PaiApiClient

    public init(apiClient: PaiApiClient) {
        self.apiClient = apiClient
    }

    public var isDirty: Bool {
        guard let loaded, let draft else { return false }
        return draft != SpokenVoiceSettingsDraft(loaded: loaded)
    }

    public var isSpeedValid: Bool {
        draft?.speed != nil
    }

    public var isTunablesValid: Bool {
        draft?.tunablesValue != nil
    }

    public var isClaudeChoiceValid: Bool {
        draft?.isClaudeChoiceValid(loaded?.computerChoices) ?? true
    }

    public var isBatchPauseValid: Bool {
        draft?.batchPauseValue != nil
    }

    public var canSave: Bool {
        loaded != nil && isDirty && draft?.asUpdate() != nil && isClaudeChoiceValid && !isSaving
    }

    public func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let settings = try await apiClient.getVoiceSettings()
            loaded = settings
            draft = SpokenVoiceSettingsDraft(loaded: settings)
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    public func save() async {
        guard canSave, let update = draft?.asUpdate() else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let settings = try await apiClient.updateVoiceSettings(update)
            loaded = settings
            draft = SpokenVoiceSettingsDraft(loaded: settings)
        } catch {
            saveError = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }
}
