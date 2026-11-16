import Foundation
import Observation

public protocol WatchKeysApiClient: Sendable {
    func listWatchKeys() async throws -> [WatchKey]
    func createWatchKey(name: String) async throws -> WatchKeyCreated
    func revokeWatchKey(id: String) async throws
}

extension PaiApiClient: WatchKeysApiClient {}

/// The keys a Garmin watch signs in with. A created key's plain text exists only in
/// ``justCreated`` until it is acknowledged: the server never serves it again.
@MainActor
@Observable
public final class WatchKeysStore {
    public private(set) var keys: [WatchKey] = []
    public private(set) var justCreated: WatchKeyCreated?
    public private(set) var errorMessage: String?

    private let api: WatchKeysApiClient

    public init(api: WatchKeysApiClient) {
        self.api = api
    }

    public func load() async {
        do {
            keys = try await api.listWatchKeys()
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the watch keys"
        }
    }

    public func create(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            justCreated = try await api.createWatchKey(name: trimmed)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not create the watch key"
            return
        }
        await load()
    }

    public func revoke(_ key: WatchKey) async {
        do {
            try await api.revokeWatchKey(id: key.id)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not revoke the watch key"
        }
        await load()
    }

    /// Forget the plain key once it has been copied or dismissed.
    public func acknowledgeCreated() {
        justCreated = nil
    }
}
