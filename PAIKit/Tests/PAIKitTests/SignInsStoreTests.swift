import XCTest

@testable import PAIKit

private actor FakeSignInsApi: SignInsApiClient {
    var own: [SignIn]
    var all: [SignIn]
    private(set) var revoked: [String] = []
    private(set) var signedOutEverywhere: [String?] = []

    init(own: [SignIn], all: [SignIn]) {
        self.own = own
        self.all = all
    }

    func listMySignIns() async throws -> [SignIn] { own }
    func listAllSignIns() async throws -> [SignIn] { all }

    func revokeSignIn(id: String) async throws -> SignIn {
        revoked.append(id)
        return SignIn(id: id, active: false)
    }

    private(set) var restored: [String] = []
    private(set) var revokedKeys: [String] = []

    func restoreSignIn(id: String) async throws -> SignIn {
        restored.append(id)
        return SignIn(id: id, active: true)
    }

    func listAllWatchKeys() async throws -> [PersonWatchKey] {
        [
            PersonWatchKey(
                id: "k1", name: "fenix", hint: "pw_aB3x", createdAt: "2026-09-01T08:00:00.000001+00:00",
                lastUsedAt: nil, userId: "u1", displayName: "Owner")
        ]
    }

    func revokeWatchKey(id: String) async throws { revokedKeys.append(id) }

    func signOutEverywhere(userId: String?) async throws -> Int {
        signedOutEverywhere.append(userId)
        return 1
    }
}

final class SignInsStoreTests: XCTestCase {
    private func all() throws -> [SignIn] {
        try JSONDecoder().decode([SignIn].self, from: Data(PaiFixtures.allSignIns.utf8))
    }

    func testTheEveryonesWatchKeysFixtureDecodesIntoPersonKeys() throws {
        let keys = try JSONDecoder().decode([PersonWatchKey].self, from: Data(PaiFixtures.allWatchKeys.utf8))
        XCTAssertEqual(keys.map(\.displayName), ["Owner", "Guest"])
    }

    func testTheFixtureDecodesWithEveryKind() throws {
        let rows = try all()
        XCTAssertEqual(rows.map(\.kind), [.app, .browser, .app, .machine])
        XCTAssertEqual(rows[0].current, true)
        XCTAssertEqual(rows[3].agentSlug, "vm")
    }

    @MainActor
    func testEveryonesListIsGroupedByPersonWithMachinesApart() async throws {
        let store = SignInsStore(scope: .everyone, api: FakeSignInsApi(own: [], all: try all()))
        await store.load()
        XCTAssertEqual(store.groups.map(\.displayName), ["Owner", "Guest"])
        XCTAssertEqual(store.groups[0].signIns.map(\.id), ["s1", "s2"])
        XCTAssertEqual(store.machines.map(\.id), ["s4"])
        XCTAssertTrue(store.groups.allSatisfy(\.hasActive))
    }

    @MainActor
    func testTheOwnListIsOneGroupAndSignsOutOnlyTheCaller() async throws {
        let api = FakeSignInsApi(own: Array(try all().prefix(2)), all: [])
        let store = SignInsStore(scope: .own, api: api)
        await store.load()
        XCTAssertEqual(store.groups.count, 1)
        await store.signOutEverywhere(of: store.groups[0])
        let sent = await api.signedOutEverywhere
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent[0], "no person named: the server takes the caller's own")
    }

    @MainActor
    func testMachinesAreRestoredAndEveryonesWatchKeysRevokedByTheirOwnIds() async throws {
        let api = FakeSignInsApi(own: [], all: try all())
        let store = SignInsStore(scope: .everyone, api: api)
        await store.load()
        await store.restore(store.machines[0])
        await store.loadWatchKeys()
        XCTAssertEqual(store.watchKeys.map(\.displayName), ["Owner"])
        await store.revokeWatchKey(store.watchKeys[0])
        let restored = await api.restored
        let revoked = await api.revokedKeys
        XCTAssertEqual(restored, ["s4"])
        XCTAssertEqual(revoked, ["k1"])
    }

    @MainActor
    func testSigningAPersonOutNamesThemAndRevokingNamesTheRow() async throws {
        let api = FakeSignInsApi(own: [], all: try all())
        let store = SignInsStore(scope: .everyone, api: api)
        await store.load()
        await store.signOutEverywhere(of: store.groups[1])
        await store.revoke(store.groups[1].signIns[0])
        let everywhere = await api.signedOutEverywhere
        let revoked = await api.revoked
        XCTAssertEqual(everywhere, ["9a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d"])
        XCTAssertEqual(revoked, ["s3"])
    }
}
