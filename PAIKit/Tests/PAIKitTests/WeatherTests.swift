import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

/// The weather wire shape, the two rows' wording, and what the location store lets through.
final class WeatherTests: XCTestCase {

    private let reference = IsoTimestamp.date(from: "2026-11-16T14:00:00+00:00")!

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func presenter(now: Date? = nil) -> WeatherPresenter {
        WeatherPresenter(now: now ?? reference, calendar: berlin)
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

    @MainActor
    func testLocationSignInIsARegistryKeyAndCanBeCleared() async throws {
        let response = try JSONDecoder().decode(
            SettingsResponse.self, from: Data(PaiFixtures.settingsRegistryOwner.utf8))
        let api = FakeSettingsRegistryApi(response: response)
        let store = SettingsRegistryStore(api: api, cache: SettingsInMemoryKeyValueStore())
        await store.load()
        XCTAssertNil(store.locationSignInId)

        await store.updatePerson(["location_sign_in_id": .string("abc")])
        XCTAssertEqual(store.locationSignInId, "abc")
        await store.updatePerson(["location_sign_in_id": .null])
        XCTAssertNil(store.locationSignInId, "a cleared phone is null, not absent")
        let sent = await api.personPatches
        XCTAssertEqual(sent.map { $0["location_sign_in_id"] }, [.string("abc"), .null])
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
        XCTAssertEqual(later.detail, "from ~17:50")
        XCTAssertEqual(presenter().laterRow(try answer("dry").later).value, "dry all day")
    }

    func testTheLaterRowNamesTheHeaviestHourAndTheAmountBesideTheStart() throws {
        let weather = try answer("showersApproaching")
        let row = presenter().laterRow(weather.later)
        XCTAssertEqual(row.caption, "heaviest ~20:00 · about 4 mm in total")
        let bars = presenter().strip(weather.later)
        XCTAssertEqual(bars.count, 12)
        XCTAssertEqual(bars.compactMap(\.label).count, 4)
        XCTAssertEqual(bars.max { $0.chance < $1.chance }?.chance, weather.later.chance)
    }

    // MARK: Forecast

    func testTheForecastSitsAroundTheRainRows() throws {
        let conditions = try answer("showersApproaching").conditions
        let summary = try XCTUnwrap(presenter().summary(conditions))
        XCTAssertEqual(summary.temperature, "9°")
        XCTAssertEqual(summary.sky, "Rain")
        XCTAssertEqual(summary.span, "High 12° · low -1° in the next 12 hours")
        let bars = presenter().temperatureBars(conditions)
        XCTAssertEqual(bars.count, 12)
        XCTAssertEqual(bars.compactMap(\.mark).map(\.hour), ["15", "18", "21", "00"])
        XCTAssertTrue(bars.allSatisfy { $0.share > 0 && $0.share <= 1 })
        XCTAssertEqual(bars.filter(\.freezing).count, 2)
        let uv = try XCTUnwrap(presenter().uv(conditions))
        XCTAssertEqual(uv.value, "1")
        XCTAssertEqual(uv.band, .low)
        XCTAssertEqual(uv.caption, "Peak 3 (moderate) at 17:00")
        XCTAssertNil(presenter().forecastNote(conditions))
    }

    func testADayIsNamedFromItsDateAsWrittenWhateverZoneThePhoneIsIn() throws {
        // The dates are the location's own; a phone far west of them must not name the day before.
        var honolulu = berlin
        honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        let days = WeatherPresenter(now: reference, calendar: honolulu)
            .days(try answer("showersApproaching").conditions)
        XCTAssertEqual(days.map(\.name), ["Today", "Tue", "Wed", "Thu"])
        XCTAssertEqual(days.map(\.chance), ["80 %", "65 %", "40 %", nil])
        XCTAssertEqual(days.map(\.rainLikely), [true, true, true, false])
    }

    func testAUvIndexIsReadAsTheWholeNumberItsBandsAreKnownBy() {
        let p = presenter()
        XCTAssertEqual(
            [0.4, 0.5, 2.4, 2.5, 5.5, 7.5, 10.5].map(p.uvBand),
            [.none, .low, .low, .moderate, .high, .veryHigh, .extreme])
        // A peak that rounds to nothing is no peak, and an hour without a value is a gap.
        let dark = WeatherConditions(
            hours: [WeatherConditionsHour(start: "2026-11-16T14:00:00+00:00", temp: 3, symbol: .cloudy)],
            uv: WeatherUv(now: 0.2, peak: 0.3, peakAt: "2026-11-16T14:00:00+00:00"))
        XCTAssertEqual(p.uv(dark)?.caption, "No UV in the next 12 hours")
        XCTAssertNil(p.uv(dark)?.bars.first?.share)
    }

    func testAForecastThatDidNotAnswerCostsOnlyItsOwnSections() throws {
        let down = try answer("sourceUnavailable").conditions
        XCTAssertNil(presenter().summary(down))
        XCTAssertNotNil(presenter().forecastNote(down))
        XCTAssertTrue(presenter().temperatureBars(down).isEmpty)
        XCTAssertNil(presenter().uv(down))
        XCTAssertTrue(presenter().days(down).isEmpty)
        // No location is said by the rain rows already.
        XCTAssertNil(presenter().forecastNote(try answer("noLocation").conditions))
    }

    func testAnAnswerWithoutTheForecastStillDecodes() throws {
        let body = PaiFixtures.weather(state: "dry", now: reference)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        object.removeValue(forKey: "conditions")
        let weather = try JSONDecoder().decode(
            WeatherResponse.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(weather.conditions)
        XCTAssertNil(presenter().summary(weather.conditions))
        XCTAssertEqual(presenter().nowRow(weather.now).verdict, .dry)
    }

    func testAnAnswerWithoutHoursDecodesWithAnEmptyStrip() throws {
        let weather = try answer("dry")
        XCTAssertTrue(weather.later.hours.isEmpty)
        XCTAssertTrue(presenter().strip(weather.later).isEmpty)
    }

    func testALaterTimeOnTheNextDayIsSaidSo() throws {
        let row = presenter().laterRow(try answer("forecastOnly").later)
        XCTAssertEqual(row.detail, "from ~tomorrow 06:00")
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

    func testTheWeatherRequestHitsTheContractsPath() async throws {
        AlarmRecordingURLProtocol.configure(reply: PaiFixtures.weather(state: nil, now: reference))
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: AlarmRecordingURLProtocol.makeSession())
        let weather = try await client.getWeather()
        XCTAssertEqual(weather.now.verdict, .rain)
        let seen = AlarmRecordingURLProtocol.seen
        XCTAssertEqual(seen.map(\.method), ["GET"])
        XCTAssertEqual(seen.map(\.path), ["/api/weather"])
    }
}
