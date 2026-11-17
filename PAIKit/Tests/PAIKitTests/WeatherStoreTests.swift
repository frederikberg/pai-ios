import XCTest

@testable import PAIKit

private actor FakeWeatherApi: WeatherApiClient {
    var answer: WeatherResponse
    private(set) var pictureRequests = 0

    init(answer: WeatherResponse) { self.answer = answer }

    func set(_ answer: WeatherResponse) { self.answer = answer }

    func getWeather() async throws -> WeatherResponse { answer }

    func getWeatherRadarPicture(size: Int) async throws -> Data? {
        pictureRequests += 1
        return Data("png".utf8)
    }
}

/// The radar picture belongs to the answer it came with.
@MainActor
final class WeatherStoreTests: XCTestCase {
    private func answer(picture: String?) -> WeatherResponse {
        WeatherResponse(
            location: nil, computedAt: "2026-11-17T15:00:00+00:00", now: WeatherNow(chance: 0, verdict: .dry),
            later: WeatherLater(chance: 0, verdict: .dry), radarPictureAt: picture, attribution: "")
    }

    func testAnAnswerWithAPictureLoadsItAndOneWithoutClearsIt() async {
        let api = FakeWeatherApi(answer: answer(picture: "2026-11-17T15:30:00+00:00"))
        let store = WeatherStore(api: api)

        await store.load()
        XCTAssertEqual(store.radarPicture, Data("png".utf8))

        await api.set(answer(picture: nil))
        await store.load()
        XCTAssertNil(store.radarPicture)
        let requests = await api.pictureRequests
        XCTAssertEqual(requests, 1)
    }
}
