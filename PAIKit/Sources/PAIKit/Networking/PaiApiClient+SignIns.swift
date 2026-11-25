import Foundation

extension PaiApiClient {

    /// Ends this device's own sign-in on the backend, which also drops its push token. The
    /// backend identifies the sign-in by the bearer and the device name the request carries.
    public func signOutCurrentSignIn() async throws {
        let _: SignIn = try await send(path: "/api/sign-ins/current/sign-out", method: "POST")
    }

    /// The signed-in person's own sign-ins, the caller's own marked `current`.
    public func listMySignIns() async throws -> [SignIn] {
        try await send(path: "/api/sign-ins")
    }

    /// Every person's and every machine's sign-ins. Owner only.
    public func listAllSignIns() async throws -> [SignIn] {
        try await send(path: "/api/sign-ins", query: [URLQueryItem(name: "everyone", value: "true")])
    }

    /// Signs one sign-in out; the answer is the row as it now stands.
    @discardableResult
    public func revokeSignIn(id: String) async throws -> SignIn {
        try await send(path: "/api/sign-ins/\(id)/revoke", method: "POST", body: nil, contentType: nil)
    }

    /// Signs every phone and browser of one person out, the caller's own without `userId`.
    @discardableResult
    public func signOutEverywhere(userId: String? = nil) async throws -> Int {
        struct Body: Encodable {
            let userId: String?
            enum CodingKeys: String, CodingKey { case userId = "user_id" }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(userId, forKey: .userId)
            }
        }
        struct Answer: Decodable { let revoked: Int }
        let answer: Answer = try await send(
            path: "/api/sign-ins/sign-out-everywhere", method: "POST", body: try Self.jsonBody(Body(userId: userId)))
        return answer.revoked
    }

    /// Every person's watch keys, each naming whose. Owner only.
    public func listAllWatchKeys() async throws -> [PersonWatchKey] {
        try await send(path: "/api/watch-keys", query: [URLQueryItem(name: "everyone", value: "true")])
    }
}
