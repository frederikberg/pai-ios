import Foundation

extension PaiApiClient {

    /// Ends this device's own sign-in on the backend, which also drops its push token. The
    /// backend identifies the sign-in by the bearer and the device name the request carries.
    public func signOutCurrentSignIn() async throws {
        let _: PaiSignIn = try await send(path: "/api/sign-ins/current/sign-out", method: "POST")
    }

    /// The signed-in person's own sign-ins, the caller's own marked `current`.
    public func listMySignIns() async throws -> [PaiSignIn] {
        try await send(path: "/api/sign-ins")
    }
}

/// A sign-in as the backend answers about it; only what the app reads back. `current` marks the
/// caller's own row in a list.
public struct PaiSignIn: Codable, Sendable, Equatable {
    public let id: String
    public let active: Bool
    public let current: Bool?

    public init(id: String, active: Bool, current: Bool? = nil) {
        self.id = id
        self.active = active
        self.current = current
    }
}
