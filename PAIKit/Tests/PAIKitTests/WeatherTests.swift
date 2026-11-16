import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

private actor FakeLocationApi: LocationApiClient {
    private(set) var posted: [LocationReport] = []
    private var signIns: [PaiSignIn]
    private var postError: Error?

    init(signIns: [PaiSignIn] = [PaiSignIn(id: "me", active: true, current: true)]) { self.signIns = signIns }

    func failPosts(with error: Error?) { postError = error }

    func postLocation(_ report: LocationReport) async throws {
        if let postError { throw postError }
        posted.append(report)
    }

    func listMySignIns() async throws -> [PaiSignIn] { signIns }
}

private actor FakeSettingsApi: UserSettingsApiClient {
    private var row: UserSettings
    init(row: UserSettings) { self.row = row }
    func getMySettings() async throws -> UserSettings { row }
    func updateMySettings(_ patch: UserSettingsPatch) async throws -> UserSettings {
        row = patch.applied(to: row)
        return row
    }
}

private actor PlaceCounter {
    private(set) var asked = 0
    func next(_ name: String?) -> String? {
        asked += 1
        return name
    }
}

private final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

/// The weather wire shape, the two rows' wording, and what the location store lets through.
final class WeatherTests: XCTestCase {

    private let reference = IsoTimestamp.date(from: "2026-11-16T14:00:00+00:00")!

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func presenter(now: Date? = nil) -> WeatherPresenter {
        WeatherPresenter(now: now ?? reference, calendar: berlin, locale: Locale(identifier: "de_DE"))
    }

    private func answer(_ state: String?) throws -> WeatherResponse {
        try JSONDecoder().decode(
            WeatherResponse.self, from: Data(PaiFixtures.weather(state: state, now: reference).utf8))
    }

    // MARK: Wire

    func testEveryFixtureStateDecodesWithTheContractsNames() throws {
        for state in PaiFixtures.weatherStates { _ = try answer(state) }
        let weather = try answer("showersApproaching")
        XCTAssertEqual(weather.now.chance, 70)
        XCTAssertEqual(weather.now.verdict, .rain)
        XCTAssertEqual(weather.now.direction, .west)
        XCTAssertEqual(weather.now.trend, .approaching)
        XCTAssertEqual(weather.now.nearestKm, 8.4)
        XCTAssertEqual(weather.later.verdict, .maybe)
        XCTAssertEqual(weather.location?.place, "Aachen")
        XCTAssertEqual(weather.location?.accuracyM, 65)
        XCTAssertNotNil(weather.now.startDate)
        XCTAssertNotNil(weather.location?.recordedDate)
    }

    func testAnUnknownVerdictDirectionAndReasonDecodeInsteadOfFailingTheAnswer() throws {
        let json = """
            {"location": null, "computed_at": "2026-11-16T14:00:00+00:00",
             "now": {"chance": 10, "verdict": "hail", "raining_now": false, "starts_at": null, "ends_at": null,
                     "nearest_km": 3, "direction": "NNW", "trend": "swirling", "method": "radar", "reason": "moon"},
             "later": {"chance": null, "verdict": "unknown", "at": null, "method": "forecast", "reason": null},
             "attribution": "x"}
            """
        let weather = try JSONDecoder().decode(WeatherResponse.self, from: Data(json.utf8))
        XCTAssertEqual(weather.now.verdict, .unrecognized("hail"))
        XCTAssertEqual(weather.now.direction?.label, "NNW")
        XCTAssertEqual(weather.now.reason, .unrecognized("moon"))
    }

    func testLocationSignInRidesUserSettingsAndCanBeCleared() throws {
        let settings = try JSONDecoder().decode(UserSettings.self, from: Data(PaiFixtures.mySettings.utf8))
        XCTAssertNil(settings.locationSignInId)
        func sent(_ patch: UserSettingsPatch) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any] ?? [:]
        }
        XCTAssertEqual(
            try sent(UserSettingsPatch(locationSignIn: .set("abc")))["location_sign_in_id"] as? String, "abc")
        XCTAssertTrue(try sent(UserSettingsPatch(locationSignIn: .clear))["location_sign_in_id"] is NSNull)
        XCTAssertTrue(
            try sent(UserSettingsPatch(emailNotifications: true)).keys.contains("location_sign_in_id") == false)
        XCTAssertEqual(UserSettingsPatch(locationSignIn: .set("abc")).applied(to: settings).locationSignInId, "abc")
    }

    func testTheLocationReportEncodesTheContractsNames() throws {
        let report = LocationReport(
            lat: 50.776, lon: 6.084, accuracyM: 65, place: "Aachen", recordedAt: "2026-11-16T12:40:00+00:00")
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys), ["lat", "lon", "accuracy_m", "place", "recorded_at", "source"])
        XCTAssertEqual(json["source"] as? String, "ios")
    }

    // MARK: Rows

    func testTheNowRowNamesTheChanceTheStartAndHowCloseTheRainIs() throws {
        let row = presenter().nowRow(try answer("showersApproaching").now)
        XCTAssertEqual(row.value, "70 %")
        XCTAssertEqual(row.detail, "from 15:20")
        XCTAssertEqual(row.caption, "showers 8 km W, closing in")
    }

    func testTheNowRowSaysWhenRainStopsWhileItIsRaining() throws {
        let row = presenter().nowRow(try answer("rainingNow").now)
        XCTAssertEqual(row.value, "100 %")
        XCTAssertNil(row.detail)
        XCTAssertEqual(row.caption, "raining now · until 15:25")
    }

    func testADryNowRowSaysDryAroundYouEvenWithRainFarAway() throws {
        let row = presenter().nowRow(try answer("dry").now)
        XCTAssertEqual(row.value, "3 %")
        XCTAssertEqual(row.caption, "dry around you")
    }

    func testTheLaterRowShowsAroundTheTimeAndDryAllDay() throws {
        let later = presenter().laterRow(try answer("showersApproaching").later)
        XCTAssertEqual(later.value, "40 %")
        XCTAssertEqual(later.detail, "around 17:50")
        XCTAssertEqual(presenter().laterRow(try answer("dry").later).value, "dry all day")
    }

    func testALaterTimeOnTheNextDayIsSaidSo() throws {
        let row = presenter().laterRow(try answer("forecastOnly").later)
        XCTAssertEqual(row.detail, "around tomorrow 06:00")
    }

    func testUnknownStatesSayWhatToDo() throws {
        let missing = try answer("noLocation")
        XCTAssertEqual(presenter().nowRow(missing.now).caption, "Pick your iPhone in Settings → Location")
        XCTAssertEqual(presenter().laterRow(missing.later).value, "–")
        let down = try answer("sourceUnavailable")
        XCTAssertEqual(presenter().nowRow(down.now).caption, "The weather sources are not answering right now")
    }

    func testAForecastOnlyAnswerSaysThereIsNoRadar() throws {
        XCTAssertEqual(
            presenter().nowRow(try answer("forecastOnly").now).caption, "from the forecast, no radar here")
    }

    func testTheFooterNamesPlaceAgeAndAttribution() throws {
        let weather = try answer("showersApproaching")
        XCTAssertEqual(presenter().footer(weather), "Aachen · 12 min ago · Radar: DWD · Forecast: Open-Meteo")
        XCTAssertEqual(presenter().footer(try answer("noLocation")), "Radar: DWD · Forecast: Open-Meteo")
    }

    func testAgeUsesTheCoarsestHonestUnit() {
        let p = presenter()
        XCTAssertEqual(p.age(of: reference.addingTimeInterval(-30)), "just now")
        XCTAssertEqual(p.age(of: reference.addingTimeInterval(-3 * 3600)), "3 h ago")
        XCTAssertEqual(p.age(of: reference.addingTimeInterval(-2 * 86400)), "2 d ago")
    }

    // MARK: Location store

    @MainActor
    private func makeStore(
        api: FakeLocationApi, chosen: String?, places: PlaceCounter = PlaceCounter(), place: String? = "Aachen",
        clock: Clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
    ) async -> LocationReportStore {
        let settings = UserSettingsStore(
            api: FakeSettingsApi(row: UserSettings(locationSignInId: chosen)), cache: SettingsInMemoryKeyValueStore())
        await settings.load()
        let store = LocationReportStore(
            api: api, userSettings: settings, cache: SettingsInMemoryKeyValueStore(),
            placeName: { _, _ in await places.next(place) }, now: { clock.date })
        await store.resolveCurrentSignIn()
        return store
    }

    private func fix(_ lat: Double = 50.77612, _ lon: Double = 6.08391, at seconds: TimeInterval = 1_800_000_000)
        -> LocationFix
    {
        LocationFix(
            latitude: lat, longitude: lon, accuracy: 64.6, timestamp: Date(timeIntervalSince1970: seconds))
    }

    @MainActor
    func testTheChosenPhoneSendsARoundedFixWithItsPlace() async throws {
        let api = FakeLocationApi()
        let store = await makeStore(api: api, chosen: "me")
        XCTAssertTrue(store.usesThisDevice)
        let delivered = await store.report(fix())
        XCTAssertTrue(delivered)
        let posted = await api.posted
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].lat, 50.776)
        XCTAssertEqual(posted[0].lon, 6.084)
        XCTAssertEqual(posted[0].accuracyM, 65)
        XCTAssertEqual(posted[0].place, "Aachen")
        XCTAssertEqual(posted[0].recordedAt, AlarmTime.wireString(Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @MainActor
    func testAPhoneThatIsNotTheChosenOneNeverSends() async {
        let api = FakeLocationApi()
        let other = await makeStore(api: api, chosen: "someone-else")
        XCTAssertFalse(other.usesThisDevice)
        let none = await makeStore(api: api, chosen: nil)
        let delivered = [await other.report(fix()), await none.report(fix())]
        XCTAssertEqual(delivered, [false, false])
        let posted = await api.posted
        XCTAssertTrue(posted.isEmpty)
    }

    @MainActor
    func testAnInvalidFixIsDropped() async {
        let api = FakeLocationApi()
        let store = await makeStore(api: api, chosen: "me")
        let invalid = LocationFix(latitude: 50, longitude: 6, accuracy: -1, timestamp: Date())
        let delivered = await store.report(invalid)
        XCTAssertFalse(delivered)
        let posted = await api.posted
        XCTAssertTrue(posted.isEmpty)
    }

    @MainActor
    func testTheSameSpotTwiceWithinHalfAMinuteIsOneReport() async {
        let api = FakeLocationApi()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = await makeStore(api: api, chosen: "me", clock: clock)
        _ = await store.report(fix())
        clock.date.addTimeInterval(10)
        let second = await store.report(fix(at: 1_800_000_010))
        XCTAssertFalse(second)
        clock.date.addTimeInterval(60)
        let third = await store.report(fix(at: 1_800_000_070))
        XCTAssertTrue(third, "a later fix at the same spot refreshes the stored age")
        let posted = await api.posted
        XCTAssertEqual(posted.count, 2)
    }

    @MainActor
    func testThePlaceNameIsKeptNearbyAndLookedUpAgainFarAway() async {
        let api = FakeLocationApi()
        let places = PlaceCounter()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = await makeStore(api: api, chosen: "me", places: places, clock: clock)
        _ = await store.report(fix(50.776, 6.084))
        clock.date.addTimeInterval(120)
        _ = await store.report(fix(50.779, 6.084, at: 1_800_000_120))  // ~330 m
        let nearby = await places.asked
        XCTAssertEqual(nearby, 1)
        clock.date.addTimeInterval(120)
        _ = await store.report(fix(50.9, 6.084, at: 1_800_000_240))  // ~14 km
        let far = await places.asked
        XCTAssertEqual(far, 2)
    }

    @MainActor
    func testAnUnresolvedPlaceIsSentAsNoneRatherThanAnOldCity() async {
        let api = FakeLocationApi()
        let store = await makeStore(api: api, chosen: "me", place: nil)
        _ = await store.report(fix())
        let posted = await api.posted
        XCTAssertNil(posted.first?.place)
    }

    @MainActor
    func testAFailedPostIsReportedAndNotRemembered() async {
        let api = FakeLocationApi()
        await api.failPosts(with: PaiError.detail("nope", statusCode: 500))
        let store = await makeStore(api: api, chosen: "me")
        let delivered = await store.report(fix())
        XCTAssertFalse(delivered)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.lastReport)
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
        let api = FakeLocationApi(signIns: [PaiSignIn(id: "x", active: true, current: false)])
        let store = await makeStore(api: api, chosen: nil)
        let on = await store.setUsesThisDevice(true)
        XCTAssertFalse(on)
        XCTAssertNotNil(store.errorMessage)
    }

    func testTheWeatherLinkOpensTheWeatherScreenFromEverySpelling() {
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://weather")!), .weather)
        XCTAssertNil(DeepLink.from(url: URL(string: "pai://weather/extra")!))
        XCTAssertEqual(DeepLink.from(webURL: URL(string: "https://pai.example.com/apps/weather")!), .weather)
        XCTAssertEqual(DeepLink.weather.routes, [.weather])
        XCTAssertEqual(DeepLink.weather.url?.absoluteString, "pai://weather")
        XCTAssertEqual(Route.named("weather", sessionID: "s"), .weather)
    }

    func testOwnerAndGuestMayOpenWeatherButAnUnknownRoleMayNot() {
        XCTAssertTrue(Capabilities(role: .owner).canOpenWeather)
        XCTAssertTrue(Capabilities(role: .guest).canOpenWeather)
        XCTAssertFalse(Capabilities.unknown.canOpenWeather)
        XCTAssertFalse(Capabilities(role: .unrecognized("x")).canOpenWeather)
    }

    func testDistanceIsRoughlyRight() {
        let meters = GeoDistance.meters(50.776, 6.084, 50.779, 6.084)
        XCTAssertEqual(meters, 334, accuracy: 5)
    }

    func testTheWeatherAndLocationRequestsHitTheContractsPaths() async throws {
        AlarmRecordingURLProtocol.configure(reply: PaiFixtures.weather(state: nil, now: reference))
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: AlarmRecordingURLProtocol.makeSession())
        let weather = try await client.getWeather()
        XCTAssertEqual(weather.now.verdict, .rain)
        AlarmRecordingURLProtocol.configure(reply: "")
        try await client.postLocation(
            LocationReport(lat: 50.776, lon: 6.084, accuracyM: nil, place: "Aachen", recordedAt: "x"))
        let seen = AlarmRecordingURLProtocol.seen
        XCTAssertEqual(seen.map(\.method), ["POST"])
        XCTAssertEqual(seen.map(\.path), ["/api/location"])
    }
}
