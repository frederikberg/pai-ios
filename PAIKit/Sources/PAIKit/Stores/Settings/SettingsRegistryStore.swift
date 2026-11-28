import Foundation
import Observation

/// What `SettingsRegistryStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol SettingsRegistryApiClient: Sendable {
    func getSettings() async throws -> SettingsResponse
    func patchPersonSettings(_ patch: [String: SettingValue]) async throws -> [String: SettingValue]
    func patchInstanceSettings(_ patch: [String: SettingValue]) async throws -> [String: SettingValue]
}

extension PaiApiClient: SettingsRegistryApiClient {}

/// The settings the server declares once in its registry: the schema every client draws rows
/// from, the caller's own values, and (for the owner) the instance's.
///
/// A change shows at once and the server's answer replaces it; a refused write puts the old
/// values back. A field saved on request writes with `optimistic: false`, so a refusal leaves
/// what was typed on screen. The last person values are kept on the phone only so the first
/// moments of a launch (before the network answers, or with none) already use the person's
/// choices.
@MainActor
@Observable
public final class SettingsRegistryStore {
    private static let cacheKey = "settingsRegistryPerson"

    /// Empty until the first answer.
    public private(set) var schema: [String: SettingSchema] = [:]
    /// The caller's own values; the cached ones until the first answer.
    public private(set) var person: [String: SettingValue]
    /// The instance's values; `nil` for a guest and until the first answer.
    public private(set) var instance: [String: SettingValue]?
    /// Whether the schema has arrived: what a screen waits for before it draws a row.
    public private(set) var isLoaded = false
    public private(set) var loadError: String?
    /// The last write that was refused, for the screen to show once.
    public private(set) var errorMessage: String?

    private let api: any SettingsRegistryApiClient
    private let cache: SettingsKeyValueStore

    public init(api: any SettingsRegistryApiClient, cache: SettingsKeyValueStore) {
        self.api = api
        self.cache = cache
        person = cache.value(forKey: Self.cacheKey) ?? [:]
    }

    public func load() async {
        do {
            let response = try await api.getSettings()
            schema = response.schema
            instance = response.instance
            keep(person: response.person)
            isLoaded = true
            loadError = nil
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not load the settings"
        }
    }

    // MARK: Rows

    /// The key as a row, or `nil` when the caller may not see it, the server keeps it off the
    /// screens, or its kind is one this build cannot draw.
    public func field(_ key: String) -> SettingField? {
        guard let schema = schema[key], schema.ui, let value = value(of: key, schema: schema) else { return nil }
        return SettingField(key: key, schema: schema, value: value)
    }

    /// Whether any of `keys` changes what guests get. The one rule for tagging an Administration card
    /// "All users"; a key the schema does not list counts as not.
    public func affectsGuests(_ keys: [String]) -> Bool {
        keys.contains { schema[$0]?.affectsGuests == true }
    }

    /// The rows of `keys`, in the order given, without the ones the caller does not have.
    public func fields(_ keys: [String]) -> [SettingField] {
        keys.compactMap(field)
    }

    private func value(of key: String, schema: SettingSchema) -> SettingValue? {
        schema.scope == .instance ? instance?[key] : person[key]
    }

    // MARK: Writing

    /// Writes any subset of the caller's keys. Returns whether the server took it.
    @discardableResult
    public func updatePerson(_ patch: [String: SettingValue], optimistic: Bool = true) async -> Bool {
        let before = person
        errorMessage = nil
        if optimistic { person = Self.applied(patch, to: person, schema: schema) }
        do {
            keep(person: try await api.patchPersonSettings(patch))
            return true
        } catch {
            person = before
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not save the setting"
            return false
        }
    }

    /// Writes any subset of the instance's keys; owner only. Returns whether the server took it.
    @discardableResult
    public func updateInstance(_ patch: [String: SettingValue], optimistic: Bool = true) async -> Bool {
        let before = instance
        errorMessage = nil
        if optimistic { instance = Self.applied(patch, to: instance ?? [:], schema: schema) }
        do {
            instance = try await api.patchInstanceSettings(patch)
            return true
        } catch {
            instance = before
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not save the setting"
            return false
        }
    }

    /// Writes one key to the scope its schema names. A key the schema does not list is not written.
    @discardableResult
    public func update(_ key: String, to value: SettingValue, optimistic: Bool = true) async -> Bool {
        switch schema[key]?.scope {
        case .instance: return await updateInstance([key: value], optimistic: optimistic)
        case .person: return await updatePerson([key: value], optimistic: optimistic)
        default: return false
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    /// The values once `patch` is applied, for showing a change before the server answers. A
    /// `null` on a key that is not nullable resets it to its default, as the server does.
    nonisolated static func applied(
        _ patch: [String: SettingValue], to values: [String: SettingValue], schema: [String: SettingSchema]
    ) -> [String: SettingValue] {
        var next = values
        for (key, value) in patch {
            if value.isNull, let entry = schema[key], !entry.nullable {
                next[key] = entry.defaultValue
            } else {
                next[key] = value
            }
        }
        return next
    }

    private func keep(person next: [String: SettingValue]) {
        person = next
        cache.setValue(next, forKey: Self.cacheKey)
    }

    // MARK: Values other layers read

    /// What a plain press on the microphone starts; live until the person's settings have been read.
    public var recordingMode: VoiceSttMode {
        guard let raw = person["recording_mode"]?.stringValue else { return .live }
        return VoiceSttMode.knownValues[raw] ?? .live
    }

    /// `nil` until the person's settings have been read.
    public var playbackSpeed: Double? { person["playback_speed"]?.doubleValue }
    /// An ElevenLabs voice id replies are read aloud in; `nil` is the default voice.
    public var playbackVoiceId: String? { person["playback_voice_id"]?.stringValue }
    public var mailFromAgents: Bool? { person["mail_from_agents"]?.boolValue }
    public var alarmRingIntervalS: Int? { person["alarm_ring_interval_s"]?.intValue }
    public var alarmRingDurationS: Int? { person["alarm_ring_duration_s"]?.intValue }
    /// The sign-in of the one iPhone that reports its location in the background; `nil` when no
    /// phone does.
    public var locationSignInId: String? { person["location_sign_in_id"]?.stringValue }

    /// The person's order of apps (``AppOrder``); empty until their settings have been read.
    public var appOrder: [String] { person[Self.appOrderKey]?.stringList ?? [] }

    static let appOrderKey = "app_order"

    /// Stores the apps as the person arranged them on this phone: `sequence` is the ids on
    /// screen with the line among them. Returns whether the server took it.
    @discardableResult
    public func setAppOrder(sequence: [String]) async -> Bool {
        let next = AppOrder.reordered(stored: appOrder, sequence: sequence)
        return await updatePerson([Self.appOrderKey: .array(next.map(SettingValue.string))])
    }
}
