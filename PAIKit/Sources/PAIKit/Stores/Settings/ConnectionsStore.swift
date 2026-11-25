import Foundation
import Observation

/// What `ConnectionsStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol ConnectionsApiClient: Sendable {
    func listConnections() async throws -> [ServiceConnection]
    func testConnection(id: String) async throws -> ConnectionTestResult
    func setConnectionAddressPart(id: String, value: String?) async throws -> ServiceConnection
}

extension PaiApiClient: ConnectionsApiClient {}

/// The outside services PAI calls: address, where the key comes from, status, what uses them, and
/// a one-call test each. A key is written through the secret routes (`WriteOnlySecretField`); this
/// store rereads the list afterwards so the status follows.
@MainActor
@Observable
public final class ConnectionsStore {
    /// `nil` until the first read succeeds.
    public private(set) var connections: [ServiceConnection]?
    public private(set) var loadError: String?
    /// The last test of each connection, by id, in this launch.
    public private(set) var tests: [String: ConnectionTestResult] = [:]
    public private(set) var testing: Set<String> = []
    public private(set) var testError: [String: String] = [:]
    public private(set) var addressError: String?

    private let api: any ConnectionsApiClient

    public init(api: any ConnectionsApiClient) {
        self.api = api
    }

    public func load() async {
        do {
            connections = try await api.listConnections()
            loadError = nil
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not load the connections"
        }
    }

    public func connections(ofKinds kinds: [ConnectionKind]) -> [ServiceConnection] {
        (connections ?? []).filter { kinds.contains($0.kind) }
    }

    /// Runs the test and keeps its answer, then rereads the list: a pass lifts a provider's
    /// trip and a failure trips it, so the status can change.
    public func test(_ connection: ServiceConnection) async {
        guard !testing.contains(connection.id) else { return }
        testing.insert(connection.id)
        testError[connection.id] = nil
        defer { testing.remove(connection.id) }
        do {
            tests[connection.id] = try await api.testConnection(id: connection.id)
        } catch {
            tests[connection.id] = nil
            testError[connection.id] = (error as? PaiError)?.userMessage ?? "The test could not be run"
        }
        await load()
    }

    /// Sets the editable part of an address; empty text goes back to the deployment's.
    @discardableResult
    public func setAddressPart(_ text: String, of connection: ServiceConnection) async -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        addressError = nil
        do {
            _ = try await api.setConnectionAddressPart(id: connection.id, value: value.isEmpty ? nil : value)
        } catch {
            addressError = (error as? PaiError)?.userMessage ?? "Could not save the address"
            return false
        }
        await load()
        return true
    }
}
