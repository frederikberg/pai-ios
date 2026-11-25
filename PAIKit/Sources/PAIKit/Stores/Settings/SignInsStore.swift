import Foundation
import Observation

/// What `SignInsStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol SignInsApiClient: Sendable {
    func listMySignIns() async throws -> [SignIn]
    func listAllSignIns() async throws -> [SignIn]
    func revokeSignIn(id: String) async throws -> SignIn
    func restoreSignIn(id: String) async throws -> SignIn
    func listAllWatchKeys() async throws -> [PersonWatchKey]
    func revokeWatchKey(id: String) async throws
    func signOutEverywhere(userId: String?) async throws -> Int
}

extension PaiApiClient: SignInsApiClient {}

/// One person's phones and browsers, as listed.
public struct SignInGroup: Equatable, Sendable, Identifiable {
    /// The person's id; empty for sign-ins that name no person.
    public let userId: String
    public let displayName: String?
    public let signIns: [SignIn]

    public var id: String { userId }

    /// Whether anything of this person is still signed in, which is what "sign out everywhere"
    /// is worth offering for.
    public var hasActive: Bool { signIns.contains { $0.active } }
}

/// The devices signed in as the caller, or (the owner's, for administration) as everyone, split
/// into the person's own phones and browsers and the machine keys that reach PAI.
@MainActor
@Observable
public final class SignInsStore {
    /// Whose sign-ins are listed.
    public enum Scope: Sendable { case own, everyone }

    public let scope: Scope
    /// `nil` until the first read succeeds.
    public private(set) var rows: [SignIn]?
    public private(set) var errorMessage: String?
    public private(set) var isBusy = false

    private let api: any SignInsApiClient

    public init(scope: Scope, api: any SignInsApiClient) {
        self.scope = scope
        self.api = api
    }

    public func load() async {
        do {
            rows = try await (scope == .own ? api.listMySignIns() : api.listAllSignIns())
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the devices"
        }
    }

    /// Phones and browsers, grouped by person in the order each person first appears. The owner's
    /// own list is one group.
    public var groups: [SignInGroup] {
        var order: [String] = []
        var byPerson: [String: [SignIn]] = [:]
        for row in rows ?? [] where row.kind != .machine {
            let person = row.userId ?? ""
            if byPerson[person] == nil { order.append(person) }
            byPerson[person, default: []].append(row)
        }
        return order.map { person in
            let list = byPerson[person] ?? []
            return SignInGroup(userId: person, displayName: list.first?.displayName, signIns: list)
        }
    }

    /// The machine identities (access keys) that have reached PAI; only an owner's `everyone` read lists them.
    public var machines: [SignIn] {
        (rows ?? []).filter { $0.kind == .machine }
    }

    /// Signs one sign-in out, then reads the list again.
    public func revoke(_ row: SignIn) async {
        await run { _ = try await self.api.revokeSignIn(id: row.id) }
    }

    /// Lets a machine key in again, then reads the list again.
    public func restore(_ row: SignIn) async {
        await run { _ = try await self.api.restoreSignIn(id: row.id) }
    }

    /// Every person's watch keys, each naming whose; read by the owner's `everyone` list only.
    public private(set) var watchKeys: [PersonWatchKey] = []

    public func loadWatchKeys() async {
        guard scope == .everyone else { return }
        do {
            watchKeys = try await api.listAllWatchKeys()
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the watch keys"
        }
    }

    public func revokeWatchKey(_ key: PersonWatchKey) async {
        await run { try await self.api.revokeWatchKey(id: key.id) }
        await loadWatchKeys()
    }

    /// Signs every phone and browser of one person out, then reads the list again. The caller's
    /// own without `userId`.
    public func signOutEverywhere(of group: SignInGroup) async {
        let target: String? = scope == .own || group.userId.isEmpty ? nil : group.userId
        await run { _ = try await self.api.signOutEverywhere(userId: target) }
    }

    private func run(_ action: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await action()
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "That did not work"
            return
        }
        await load()
    }
}
