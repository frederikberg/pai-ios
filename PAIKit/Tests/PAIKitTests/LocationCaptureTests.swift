import XCTest

@testable import PAIKit

private actor FakeLocationApi: LocationApiClient {
    private(set) var batches: [[LocationPoint]] = []
    private(set) var monitorReads = 0
    private var signIns: [SignIn]
    private var postError: Error?
    private var version: String
    private var places: [MonitoredPlace]

    init(
        signIns: [SignIn] = [SignIn(id: "me", active: true, current: true)], version: String = "v1",
        places: [MonitoredPlace] = []
    ) {
        self.signIns = signIns
        self.version = version
        self.places = places
    }

    func failPosts(with error: Error?) { postError = error }
    func serve(version: String, places: [MonitoredPlace]) {
        self.version = version
        self.places = places
    }

    var posted: [LocationPoint] { batches.flatMap { $0 } }

    func postLocationPoints(_ points: [LocationPoint]) async throws -> LocationPointsAnswer {
        if let postError { throw postError }
        batches.append(points)
        return LocationPointsAnswer(stored: points.count, merged: 0, rejected: 0, history: true, placesVersion: version)
    }

    func getPlacesMonitor() async throws -> PlacesMonitorAnswer {
        monitorReads += 1
        return PlacesMonitorAnswer(places: places, placesVersion: version)
    }

    func listMySignIns() async throws -> [SignIn] { signIns }
}

private actor PlaceCounter {
    private(set) var asked = 0
    func next(_ name: String?) -> String? {
        asked += 1
        return name
    }
}

/// What the phone records and how it gets to the server: points, the queue behind them, the
/// geofence plan and the store that decides who records at all. Places here are invented.
final class LocationCaptureTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pai-test-location-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var queueFile: URL { directory.appendingPathComponent("queue.jsonl") }

    private func point(
        _ kind: LocationPointKind = .fix, at seconds: TimeInterval = 1_800_000_000, lat: Double = 10.0,
        lon: Double = -30.0
    ) -> LocationPoint {
        LocationPoint(
            lat: lat, lon: lon, accuracyM: 40, recordedAt: AlarmTime.wireString(Date(timeIntervalSince1970: seconds)),
            kind: kind)
    }

    // MARK: Points

    func testAVisitBecomesAnArrivalAndADepartureAtItsCoordinate() {
        let visit = VisitSample(
            latitude: 10.0, longitude: -30.0, accuracy: 35.4, arrival: Date(timeIntervalSince1970: 1_800_000_000),
            departure: Date(timeIntervalSince1970: 1_800_003_600))
        let points = LocationPointMapping.points(for: visit, locality: "Springfield")
        XCTAssertEqual(points.map(\.kind), [.visitArrive, .visitDepart])
        XCTAssertEqual(points.map(\.accuracyM), [35, 35])
        XCTAssertEqual(points.map(\.locality), ["Springfield", "Springfield"])
        XCTAssertEqual(points[1].recordedAt, AlarmTime.wireString(Date(timeIntervalSince1970: 1_800_003_600)))
    }

    func testAVisitStillGoingOnHasNoDepartureAndAnUnseenArrivalHasNoArrival() {
        let ongoing = VisitSample(
            latitude: 10, longitude: -30, accuracy: 30, arrival: Date(timeIntervalSince1970: 1_800_000_000),
            departure: nil)
        XCTAssertEqual(LocationPointMapping.points(for: ongoing, locality: nil).map(\.kind), [.visitArrive])
        let unseen = VisitSample(
            latitude: 10, longitude: -30, accuracy: 30, arrival: nil,
            departure: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(LocationPointMapping.points(for: unseen, locality: nil).map(\.kind), [.visitDepart])
        let invalid = VisitSample(latitude: 10, longitude: -30, accuracy: -1, arrival: Date(), departure: nil)
        XCTAssertTrue(LocationPointMapping.points(for: invalid, locality: nil).isEmpty)
    }

    func testAPointCarriesFiveDecimalsAndTheContractsNames() throws {
        let precise = LocationPoint(
            lat: 10.1234567, lon: -30.7654321, accuracyM: nil, recordedAt: "x", kind: .regionEnter, placeId: "p1")
        XCTAssertEqual(precise.lat, 10.12346)
        XCTAssertEqual(precise.lon, -30.76543)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(LocationPointsRequest(points: [precise]))) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "ios")
        let sent = try XCTUnwrap((json["points"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(sent.keys), ["lat", "lon", "recorded_at", "kind", "place_id"])
        XCTAssertEqual(sent["kind"] as? String, "region_enter")
    }

    func testARegionEventSitsAtThePlacesCenterAndClaimsNoAccuracy() {
        let place = MonitoredPlace(id: "p1", lat: 10.0, lon: -30.0, radiusM: 300)
        let entered = LocationPointMapping.point(
            for: place, entered: true, at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(entered.kind, .regionEnter)
        XCTAssertEqual(entered.placeId, "p1")
        XCTAssertNil(entered.accuracyM)
        XCTAssertEqual(
            LocationPointMapping.point(for: place, entered: false, at: Date()).kind, .regionExit)
    }

    // MARK: Queue

    func testTheQueueSurvivesARelaunchInOrder() async {
        let first = LocationQueue(fileURL: queueFile)
        await first.append(point(.fix, at: 1_800_000_000))
        await first.append(point(.visitArrive, at: 1_800_000_100))
        let second = LocationQueue(fileURL: queueFile)
        let held = await second.all
        XCTAssertEqual(held.map(\.kind), [.fix, .visitArrive])
        XCTAssertEqual(
            held.map(\.recordedAt),
            [point(.fix, at: 1_800_000_000).recordedAt, point(.visitArrive, at: 1_800_000_100).recordedAt])
    }

    func testAFullQueueDropsTheOldestFixesAndNeverAVisitOrRegionEvent() async {
        let queue = LocationQueue(fileURL: queueFile)
        await queue.append(point(.visitArrive, at: 1))
        for index in 0..<LocationQueue.capacity {
            await queue.append(point(.fix, at: 100 + Double(index)))
        }
        await queue.append(point(.regionExit, at: 99_999))
        let held = await queue.all
        XCTAssertEqual(held.count, LocationQueue.capacity)
        XCTAssertEqual(held.first?.kind, .visitArrive, "the oldest row is a visit and stays")
        XCTAssertEqual(held.last?.kind, .regionExit)
        XCTAssertEqual(held.filter { $0.kind == .fix }.count, LocationQueue.capacity - 2)
        XCTAssertFalse(
            held.contains { $0.recordedAt == point(.fix, at: 100).recordedAt }, "the oldest fix is the one dropped")
    }

    func testAQueueOfNothingButVisitsGrowsPastTheLimitRatherThanLoseOne() async {
        let queue = LocationQueue(fileURL: queueFile)
        for index in 0...LocationQueue.capacity {
            await queue.append(point(.visitArrive, at: Double(index)))
        }
        let count = await queue.count
        XCTAssertEqual(count, LocationQueue.capacity + 1)
    }

    func testBatchesAreTheOldestFiveHundredAndRemoveDropsOnlyWhatArrived() async {
        let queue = LocationQueue(fileURL: queueFile)
        for index in 0..<520 { await queue.append(point(.fix, at: Double(index))) }
        let batch = await queue.batch()
        XCTAssertEqual(batch.count, 500)
        XCTAssertEqual(batch.first?.recordedAt, point(.fix, at: 0).recordedAt)
        await queue.remove(first: batch.count)
        let rest = await queue.all
        XCTAssertEqual(rest.count, 20)
        XCTAssertEqual(rest.first?.recordedAt, point(.fix, at: 500).recordedAt)
        let reread = LocationQueue(fileURL: queueFile)
        let persisted = await reread.count
        XCTAssertEqual(persisted, 20, "the removal reached the file")
    }

    // MARK: Geofence plan

    private func places(_ count: Int) -> [MonitoredPlace] {
        (0..<count).map { MonitoredPlace(id: "p\($0)", lat: 10 + Double($0) * 0.01, lon: -30, radiusM: 300) }
    }

    func testAnUnchangedSetAddsOnlyWhatIsMissingAndRemovesWhatIsGone() {
        let plan = PlaceMonitorPlan.make(desired: places(3), held: ["p0", "p1", "old"], versionChanged: false)
        XCTAssertEqual(plan.add.map(\.id), ["p2"])
        XCTAssertEqual(plan.remove, ["old"])
    }

    func testAChangedVersionAddsEveryPlaceAgainSoAMovedCircleIsReplaced() {
        let plan = PlaceMonitorPlan.make(desired: places(2), held: ["p0", "p1"], versionChanged: true)
        XCTAssertEqual(plan.add.map(\.id), ["p0", "p1"])
        XCTAssertTrue(plan.remove.isEmpty)
    }

    func testNoMoreThanTwentyPlacesAreWatchedAndTheFirstOnesWin() {
        let plan = PlaceMonitorPlan.make(desired: places(25), held: [], versionChanged: false)
        XCTAssertEqual(plan.add.count, 20)
        XCTAssertEqual(plan.add.first?.id, "p0")
        XCTAssertEqual(plan.add.last?.id, "p19")
        let held = Set(places(25).map(\.id))
        XCTAssertEqual(PlaceMonitorPlan.make(desired: places(25), held: held, versionChanged: false).remove.count, 5)
    }

    func testASmallPlaceIsWatchedAtLeastAsWideAsRegionsAreReliable() {
        XCTAssertEqual(PlaceMonitorPlan.radius(of: MonitoredPlace(id: "a", lat: 0, lon: 0, radiusM: 100)), 150)
        XCTAssertEqual(PlaceMonitorPlan.radius(of: MonitoredPlace(id: "a", lat: 0, lon: 0, radiusM: 400)), 400)
    }

    // MARK: Store

    @MainActor
    private func makeStore(
        api: FakeLocationApi, chosen: String?, owner: Bool = true, places: PlaceCounter = PlaceCounter(),
        place: String? = "Springfield", cache: SettingsInMemoryKeyValueStore = SettingsInMemoryKeyValueStore()
    ) async -> LocationReportStore {
        var response = try! JSONDecoder().decode(
            SettingsResponse.self, from: Data(PaiFixtures.settingsRegistryOwner.utf8))
        var person = response.person
        person["location_sign_in_id"] = chosen.map { .string($0) } ?? .null
        response = SettingsResponse(schema: response.schema, person: person, instance: response.instance)
        let settings = SettingsRegistryStore(
            api: FakeSettingsRegistryApi(response: response), cache: SettingsInMemoryKeyValueStore())
        await settings.load()
        let store = LocationReportStore(
            api: api, settings: settings, cache: cache, queue: LocationQueue(fileURL: queueFile),
            placeName: { _, _ in await places.next(place) },
            capabilities: { Capabilities(role: owner ? .owner : .guest) })
        await store.resolveCurrentSignIn()
        store.syncRole()
        return store
    }

    private func fix(_ lat: Double = 10.00112, _ lon: Double = -30.00221, at seconds: TimeInterval = 1_800_000_000)
        -> LocationFix
    {
        LocationFix(latitude: lat, longitude: lon, accuracy: 64.6, timestamp: Date(timeIntervalSince1970: seconds))
    }

    @MainActor
    func testTheChosenPhoneSendsAFixWithItsPlaceAndFiveDecimals() async throws {
        let api = FakeLocationApi()
        let store = await makeStore(api: api, chosen: "me")
        XCTAssertTrue(store.usesThisDevice)
        let delivered = await store.report(fix())
        XCTAssertTrue(delivered)
        let posted = await api.posted
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].lat, 10.00112)
        XCTAssertEqual(posted[0].lon, -30.00221)
        XCTAssertEqual(posted[0].accuracyM, 65)
        XCTAssertEqual(posted[0].locality, "Springfield")
        XCTAssertEqual(posted[0].kind, .fix)
    }

    @MainActor
    func testAPhoneThatIsNotTheChosenOneNeverQueuesOrSends() async {
        let api = FakeLocationApi()
        let other = await makeStore(api: api, chosen: "someone-else")
        XCTAssertFalse(other.usesThisDevice)
        let none = await makeStore(api: api, chosen: nil)
        let delivered = [await other.report(fix()), await none.report(fix())]
        XCTAssertEqual(delivered, [false, false])
        await other.recordVisit(
            VisitSample(latitude: 10, longitude: -30, accuracy: 30, arrival: Date(), departure: nil))
        await other.recordRegion(placeId: "p", entered: true, at: Date())
        let posted = await api.posted
        XCTAssertTrue(posted.isEmpty)
        let queued = await LocationQueue(fileURL: queueFile).count
        XCTAssertEqual(queued, 0)
    }

    @MainActor
    func testAnInvalidFixIsDropped() async {
        let api = FakeLocationApi()
        let store = await makeStore(api: api, chosen: "me")
        let delivered = await store.report(LocationFix(latitude: 10, longitude: -30, accuracy: -1, timestamp: Date()))
        XCTAssertFalse(delivered)
        let posted = await api.posted
        XCTAssertTrue(posted.isEmpty)
    }

    @MainActor
    func testAGuestsPhoneSendsFixesButKeepsNoVisitsOrRegionEvents() async {
        let api = FakeLocationApi()
        let store = await makeStore(api: api, chosen: "me", owner: false)
        XCTAssertTrue(store.usesThisDevice)
        XCTAssertFalse(store.keepsHistory)
        _ = await store.report(fix())
        await store.recordVisit(
            VisitSample(latitude: 10, longitude: -30, accuracy: 30, arrival: Date(), departure: nil))
        await store.refreshPlaces()
        let posted = await api.posted
        XCTAssertEqual(posted.map(\.kind), [.fix])
        let reads = await api.monitorReads
        XCTAssertEqual(reads, 0, "a guest has no places to watch")
    }

    @MainActor
    func testAFailedPostKeepsThePointQueuedAndTheNextFlushSendsIt() async {
        let api = FakeLocationApi()
        await api.failPosts(with: PaiError.transport("offline"))
        let store = await makeStore(api: api, chosen: "me")
        let delivered = await store.report(fix())
        XCTAssertFalse(delivered)
        let queued = await LocationQueue(fileURL: queueFile).count
        XCTAssertEqual(queued, 1)
        await api.failPosts(with: nil)
        await store.flush()
        let posted = await api.posted
        XCTAssertEqual(posted.count, 1)
        let after = await LocationQueue(fileURL: queueFile).count
        XCTAssertEqual(after, 0)
    }

    @MainActor
    func testABatchTheServerRejectsOutrightIsDroppedSoItCannotBlockTheRest() async {
        let api = FakeLocationApi()
        await api.failPosts(with: PaiError.detail("invalid point", statusCode: 422))
        let store = await makeStore(api: api, chosen: "me")
        _ = await store.report(fix())
        let queued = await LocationQueue(fileURL: queueFile).count
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(store.errorMessage, "invalid point")
    }

    @MainActor
    func testAnOfflineBacklogGoesOutInBatchesOfFiveHundred() async throws {
        let api = FakeLocationApi()
        let queue = LocationQueue(fileURL: queueFile)
        for index in 0..<1200 { await queue.append(point(.fix, at: Double(index))) }
        let store = await makeStore(api: api, chosen: "me")
        await store.flush()
        let sizes = await api.batches.map(\.count)
        XCTAssertEqual(sizes, [500, 500, 200])
    }

    @MainActor
    func testARegionEventIsPlacedAtThePlaceTheServerNamedAndSurvivesARelaunch() async throws {
        let cache = SettingsInMemoryKeyValueStore()
        let api = FakeLocationApi(
            version: "v1", places: [MonitoredPlace(id: "p1", lat: 10.0, lon: -30.0, radiusM: 300)])
        let store = await makeStore(api: api, chosen: "me", cache: cache)
        await store.refreshPlaces()
        XCTAssertEqual(store.monitoredPlaces.map(\.id), ["p1"])

        // A relaunch brings a store with no network answer yet: the places come from disk.
        let relaunched = await makeStore(api: api, chosen: "me", cache: cache)
        XCTAssertEqual(relaunched.monitoredPlaces.map(\.id), ["p1"])
        await relaunched.recordRegion(placeId: "p1", entered: true, at: Date(timeIntervalSince1970: 1_800_000_000))
        await relaunched.recordRegion(placeId: "unknown", entered: true, at: Date())
        let posted = await api.posted
        XCTAssertEqual(posted.map(\.kind), [.regionEnter])
        XCTAssertEqual(posted.first?.placeId, "p1")
        XCTAssertEqual(posted.first?.lat, 10.0)
    }

    @MainActor
    func testTheOwnersRoleIsRememberedSoARelaunchBeforeMeAnswersStillRecords() async {
        let cache = SettingsInMemoryKeyValueStore()
        let api = FakeLocationApi()
        _ = await makeStore(api: api, chosen: "me", cache: cache)
        // The next launch: `/api/me` has not answered, so the capabilities are unknown.
        var response = try! JSONDecoder().decode(
            SettingsResponse.self, from: Data(PaiFixtures.settingsRegistryOwner.utf8))
        var person = response.person
        person["location_sign_in_id"] = .string("me")
        response = SettingsResponse(schema: response.schema, person: person, instance: response.instance)
        let settings = SettingsRegistryStore(
            api: FakeSettingsRegistryApi(response: response), cache: SettingsInMemoryKeyValueStore())
        await settings.load()
        let store = LocationReportStore(
            api: api, settings: settings, cache: cache, queue: LocationQueue(fileURL: queueFile),
            placeName: { _, _ in nil }, capabilities: { .unknown })
        await store.resolveCurrentSignIn()
        XCTAssertTrue(store.keepsHistory)
    }

    @MainActor
    func testANewPlacesVersionInAnAnswerReadsThePlacesAgainAndTellsTheAppleHalf() async {
        let api = FakeLocationApi(version: "v1", places: [MonitoredPlace(id: "p1", lat: 10, lon: -30, radiusM: 300)])
        let store = await makeStore(api: api, chosen: "me")
        var told: [(Int, Bool)] = []
        store.onPlacesChange = { places, changed in told.append((places.count, changed)) }
        _ = await store.report(fix())
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told.first?.0, 1)
        XCTAssertEqual(told.first?.1, true)
        _ = await store.report(fix(at: 1_800_000_100))
        XCTAssertEqual(told.count, 1, "an unchanged version is not read again")
        await api.serve(version: "v2", places: [])
        _ = await store.report(fix(at: 1_800_000_200))
        XCTAssertEqual(told.count, 2)
        XCTAssertEqual(told.last?.0, 0)
    }

    @MainActor
    func testThePlaceNameIsKeptNearbyAndLookedUpAgainFarAway() async {
        let api = FakeLocationApi()
        let places = PlaceCounter()
        let store = await makeStore(api: api, chosen: "me", places: places)
        _ = await store.report(fix(10.0, -30.0))
        _ = await store.report(fix(10.003, -30.0, at: 1_800_000_120))  // ~330 m
        let nearby = await places.asked
        XCTAssertEqual(nearby, 1)
        _ = await store.report(fix(10.2, -30.0, at: 1_800_000_240))  // ~22 km
        let far = await places.asked
        XCTAssertEqual(far, 2)
    }

    @MainActor
    func testAnUnresolvedPlaceIsSentAsNoneRatherThanAnOldCity() async {
        let api = FakeLocationApi()
        let store = await makeStore(api: api, chosen: "me", place: nil)
        _ = await store.report(fix())
        let posted = await api.posted
        XCTAssertNil(posted.first?.locality)
    }

    @MainActor
    func testTheToggleWritesThisPhonesSignInAndTurnsOffOnlyItsOwnChoice() async {
        let api = FakeLocationApi()
        let store = await makeStore(api: api, chosen: "other")
        XCTAssertFalse(store.usesThisDevice)
        let off = await store.setUsesThisDevice(false)
        XCTAssertTrue(off)
        XCTAssertFalse(store.usesThisDevice)

        let on = await store.setUsesThisDevice(true)
        XCTAssertTrue(on)
        XCTAssertTrue(store.usesThisDevice)

        _ = await store.setUsesThisDevice(false)
        XCTAssertFalse(store.usesThisDevice)
    }

    @MainActor
    func testTheToggleRefusesWhenThisSignInCannotBeNamed() async {
        let api = FakeLocationApi(signIns: [SignIn(id: "x", active: true, current: false)])
        let store = await makeStore(api: api, chosen: nil)
        let on = await store.setUsesThisDevice(true)
        XCTAssertFalse(on)
        XCTAssertNotNil(store.errorMessage)
    }

    // MARK: Wire

    func testThePointsAndPlacesRequestsHitTheContractsPaths() async throws {
        PaiStubURLProtocol.reset()
        defer { PaiStubURLProtocol.reset() }
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: PaiFixtures.data(PaiFixtures.locationPointsAnswer))
        let answer = try await client.postLocationPoints([point()])
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/location/points")
        XCTAssertEqual(answer.placesVersion, "v-fixture-1")
        XCTAssertTrue(answer.history)

        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: PaiFixtures.data(PaiFixtures.placesMonitor))
        let monitor = try await client.getPlacesMonitor()
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/places/monitor")
        XCTAssertEqual(monitor.places.count, 2)
        XCTAssertEqual(monitor.places[0].radiusM, 300)
    }
}
