import XCTest

@testable import PAIKit

private final class TestClock: @unchecked Sendable {
    var date: Date
    var zone: TimeZone
    init(_ iso: String, zone: String = "Europe/Berlin") {
        date = IsoTimestamp.date(from: iso)!
        self.zone = TimeZone(identifier: zone)!
    }
}

/// The window, the PIN guard and the one answer to "is it sleep time". Times are written with
/// their offsets: Berlin is +01:00 in winter and +02:00 in summer.
final class SleepModeTests: XCTestCase {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private func at(_ iso: String) -> Date { IsoTimestamp.date(from: iso)! }

    // MARK: Window

    func testAWindowIsNeverEmptyOrOutsideTheDay() {
        XCTAssertNil(SleepWindow(startMinute: 600, endMinute: 600))
        XCTAssertNil(SleepWindow(startMinute: -1, endMinute: 60))
        XCTAssertNil(SleepWindow(startMinute: 0, endMinute: 1440))
        XCTAssertEqual(SleepWindow.standard.label, "22:00–05:00")
    }

    func testTheWindowStartsAtItsStartAndEndsAtItsEnd() {
        let window = SleepWindow.standard
        // Winter: Berlin is UTC+1.
        for (iso, inside) in [
            ("2026-11-25T21:59:59+01:00", false), ("2026-11-25T22:00:00+01:00", true),
            ("2026-11-25T23:59:59+01:00", true), ("2026-11-26T00:00:00+01:00", true),
            ("2026-11-26T04:59:59+01:00", true), ("2026-11-26T05:00:00+01:00", false),
            ("2026-11-26T12:00:00+01:00", false),
        ] {
            XCTAssertEqual(window.contains(at(iso), in: berlin), inside, iso)
        }
    }

    func testAWindowWithinOneDayDoesNotCrossMidnight() throws {
        let nap = try XCTUnwrap(SleepWindow(startMinute: 13 * 60, endMinute: 14 * 60 + 30))
        XCTAssertFalse(nap.contains(at("2026-11-25T12:59:59+01:00"), in: berlin))
        XCTAssertTrue(nap.contains(at("2026-11-25T13:00:00+01:00"), in: berlin))
        XCTAssertTrue(nap.contains(at("2026-11-25T14:29:59+01:00"), in: berlin))
        XCTAssertFalse(nap.contains(at("2026-11-25T14:30:00+01:00"), in: berlin))
    }

    func testTheWindowEndsAtItsEndWhateverTheDayBeganWith() {
        let window = SleepWindow.standard
        XCTAssertEqual(
            window.end(ofWindowContaining: at("2026-11-25T23:00:00+01:00"), in: berlin),
            at("2026-11-26T05:00:00+01:00"))
        XCTAssertEqual(
            window.end(ofWindowContaining: at("2026-11-26T03:00:00+01:00"), in: berlin),
            at("2026-11-26T05:00:00+01:00"))
        XCTAssertNil(window.end(ofWindowContaining: at("2026-11-26T12:00:00+01:00"), in: berlin))
    }

    func testTheNextBoundaryIsTheNextStartOrEnd() {
        let window = SleepWindow.standard
        XCTAssertEqual(
            window.nextBoundary(after: at("2026-11-25T12:00:00+01:00"), in: berlin), at("2026-11-25T22:00:00+01:00"))
        XCTAssertEqual(
            window.nextBoundary(after: at("2026-11-25T22:00:00+01:00"), in: berlin), at("2026-11-26T05:00:00+01:00"),
            "strictly after: at the start the next change is the end")
        XCTAssertEqual(
            window.nextBoundary(after: at("2026-11-26T05:00:00+01:00"), in: berlin), at("2026-11-26T22:00:00+01:00"))
    }

    /// The clock jumps from 02:00 to 03:00 on 2026-03-29: the night is one hour shorter on the
    /// clock face and the window still reads 22:00 to 05:00.
    func testTheSpringChangeKeepsTheWindowOnTheDial() {
        let window = SleepWindow.standard
        XCTAssertTrue(window.contains(at("2026-03-29T01:30:00+01:00"), in: berlin))
        XCTAssertTrue(window.contains(at("2026-03-29T03:30:00+02:00"), in: berlin), "03:30 on the dial")
        XCTAssertTrue(window.contains(at("2026-03-29T04:59:59+02:00"), in: berlin))
        XCTAssertFalse(window.contains(at("2026-03-29T05:00:00+02:00"), in: berlin))
        XCTAssertEqual(
            window.end(ofWindowContaining: at("2026-03-28T23:00:00+01:00"), in: berlin),
            at("2026-03-29T05:00:00+02:00"))
    }

    /// The clock goes back from 03:00 to 02:00 on 2026-10-25: 02:00 to 03:00 happens twice.
    func testTheAutumnChangeKeepsTheWindowOnTheDial() {
        let window = SleepWindow.standard
        XCTAssertTrue(window.contains(at("2026-10-25T02:30:00+02:00"), in: berlin))
        XCTAssertTrue(window.contains(at("2026-10-25T02:30:00+01:00"), in: berlin), "the second 02:30")
        XCTAssertTrue(window.contains(at("2026-10-25T04:59:59+01:00"), in: berlin))
        XCTAssertFalse(window.contains(at("2026-10-25T05:00:00+01:00"), in: berlin))
        XCTAssertEqual(
            window.end(ofWindowContaining: at("2026-10-24T23:00:00+02:00"), in: berlin),
            at("2026-10-25T05:00:00+01:00"))
    }

    func testAnotherTimeZoneIsAnotherDial() {
        let window = SleepWindow.standard
        let newYork = TimeZone(identifier: "America/New_York")!
        // 23:00 in Berlin is 17:00 in New York.
        let moment = at("2026-11-25T23:00:00+01:00")
        XCTAssertTrue(window.contains(moment, in: berlin))
        XCTAssertFalse(window.contains(moment, in: newYork))
    }

    // MARK: PIN

    func testAPinIsFourToSixDigits() {
        for good in ["1234", "12345", "123456"] { XCTAssertTrue(SleepPin.isWellFormed(good), good) }
        for bad in ["", "123", "1234567", "12a4", "١٢٣٤", "12 4"] { XCTAssertFalse(SleepPin.isWellFormed(bad), bad) }
    }

    func testThePinIsKeptAsASaltedDigest() throws {
        let pin = SleepPin(pin: "4711", salt: "00112233445566778899aabbccddeeff")
        XCTAssertTrue(pin.matches("4711"))
        XCTAssertFalse(pin.matches("4712"))
        let stored = String(data: try JSONEncoder().encode(pin), encoding: .utf8) ?? ""
        XCTAssertFalse(stored.contains("4711"))
        XCTAssertNotEqual(
            pin.digest, SleepPin(pin: "4711", salt: "ffeeddccbbaa99887766554433221100").digest, "the salt matters")
        XCTAssertEqual(SleepPin.randomSalt().count, 32)
    }

    // MARK: Store

    private func store(
        _ clock: TestClock, storage: SettingsInMemoryKeyValueStore = .init(), enabled: Bool = true
    ) -> SleepModeStore {
        let store = SleepModeStore(
            storage: storage, now: { clock.date }, zone: { clock.zone },
            makeSalt: { "00112233445566778899aabbccddeeff" })
        if enabled { store.enable(window: .standard, pin: "1234") }
        return store
    }

    func testItIsOffUntilSomeoneEnablesIt() {
        let clock = TestClock("2026-11-25T23:30:00+01:00")
        let off = store(clock, enabled: false)
        XCTAssertFalse(off.isAsleep, "inside the window, but never turned on")
        XCTAssertNil(off.window)
        XCTAssertNil(off.nextBoundary)
        XCTAssertTrue(store(clock).isAsleep)
    }

    func testItNeedsAWellFormedPinToTurnOn() {
        let clock = TestClock("2026-11-25T23:30:00+01:00")
        let off = store(clock, enabled: false)
        XCTAssertFalse(off.enable(window: .standard, pin: "12"))
        XCTAssertFalse(off.isEnabled)
    }

    func testTheAnswerFollowsTheClockWhenItIsRefreshed() {
        let clock = TestClock("2026-11-25T21:59:59+01:00")
        let sleeping = store(clock)
        XCTAssertFalse(sleeping.isAsleep)
        XCTAssertEqual(sleeping.nextBoundary, at("2026-11-25T22:00:00+01:00"))
        clock.date = at("2026-11-25T22:00:00+01:00")
        sleeping.refresh()
        XCTAssertTrue(sleeping.isAsleep)
        XCTAssertEqual(sleeping.nextBoundary, at("2026-11-26T05:00:00+01:00"))
        clock.date = at("2026-11-26T05:00:00+01:00")
        sleeping.refresh()
        XCTAssertFalse(sleeping.isAsleep)
    }

    func testAChangeOfTimeZoneMovesTheWindow() {
        let clock = TestClock("2026-11-25T23:30:00+01:00")
        let sleeping = store(clock)
        XCTAssertTrue(sleeping.isAsleep)
        clock.zone = TimeZone(identifier: "America/New_York")!
        sleeping.refresh()
        XCTAssertFalse(sleeping.isAsleep, "17:30 where the phone now is")
    }

    func testSleepBeginningIsReportedOncePerWindow() {
        let clock = TestClock("2026-11-25T21:00:00+01:00")
        let sleeping = store(clock)
        var began = 0
        sleeping.onSleepBegan = { began += 1 }
        sleeping.refresh()
        XCTAssertEqual(began, 0)
        clock.date = at("2026-11-25T22:00:01+01:00")
        sleeping.refresh()
        sleeping.refresh()
        XCTAssertEqual(began, 1, "refreshing inside the window is not a beginning")
        clock.date = at("2026-11-26T06:00:00+01:00")
        sleeping.refresh()
        clock.date = at("2026-11-26T22:30:00+01:00")
        sleeping.refresh()
        XCTAssertEqual(began, 2)
    }

    func testEveryChangeNeedsThePin() {
        let clock = TestClock("2026-11-25T12:00:00+01:00")
        let sleeping = store(clock)
        let other = SleepWindow(startMinute: 23 * 60, endMinute: 6 * 60)!
        XCTAssertEqual(sleeping.setWindow(other, pin: "0000"), .wrong)
        XCTAssertEqual(sleeping.settings.window, .standard)
        XCTAssertEqual(sleeping.setWindow(other, pin: "1234"), .accepted)
        XCTAssertEqual(sleeping.settings.window, other)

        XCTAssertEqual(sleeping.changePin(from: "0000", to: "5678"), .wrong)
        XCTAssertEqual(sleeping.changePin(from: "1234", to: "5678"), .accepted)
        XCTAssertEqual(sleeping.changePin(from: "1234", to: "9999"), .wrong, "the old PIN no longer opens it")
        XCTAssertEqual(sleeping.changePin(from: "5678", to: "12"), .wrong, "a malformed new PIN is refused")

        XCTAssertEqual(sleeping.disable(pin: "0000"), .wrong)
        XCTAssertTrue(sleeping.isEnabled)
        XCTAssertEqual(sleeping.disable(pin: "5678"), .accepted)
        XCTAssertFalse(sleeping.isEnabled)
        XCTAssertNil(sleeping.settings.pin, "the PIN goes with it")
    }

    func testThreeWrongTriesInARowPauseTheNextOne() {
        let clock = TestClock("2026-11-25T12:00:00+01:00")
        let sleeping = store(clock)
        XCTAssertEqual(sleeping.check("1"), .wrong)
        XCTAssertEqual(sleeping.check("2"), .wrong)
        XCTAssertEqual(sleeping.check("3"), .wrong)
        guard case .wait(let seconds) = sleeping.check("1234") else { return XCTFail("expected a wait") }
        XCTAssertEqual(seconds, 1, accuracy: 0.001)
        clock.date = clock.date.addingTimeInterval(1.5)
        XCTAssertEqual(sleeping.check("1234"), .accepted)
        XCTAssertEqual(sleeping.check("0"), .wrong, "a right PIN starts the count over")
    }

    func testWakingEarlyLastsUntilTheWindowEndsThenTheNextOneApplies() {
        let clock = TestClock("2026-11-25T23:30:00+01:00")
        let sleeping = store(clock)
        XCTAssertTrue(sleeping.isAsleep)
        XCTAssertEqual(sleeping.wakeEarly(pin: "0000"), .wrong)
        XCTAssertTrue(sleeping.isAsleep)
        XCTAssertEqual(sleeping.wakeEarly(pin: "1234"), .accepted)
        XCTAssertFalse(sleeping.isAsleep)
        XCTAssertEqual(sleeping.settings.skipUntil, at("2026-11-26T05:00:00+01:00"))
        XCTAssertEqual(sleeping.nextBoundary, at("2026-11-26T05:00:00+01:00"))

        clock.date = at("2026-11-26T03:00:00+01:00")
        sleeping.refresh()
        XCTAssertFalse(sleeping.isAsleep, "still inside the window, still woken")
        clock.date = at("2026-11-26T22:00:00+01:00")
        sleeping.refresh()
        XCTAssertTrue(sleeping.isAsleep, "the next night is a night again")
    }

    func testTheSettingsSurviveARelaunch() {
        let storage = SettingsInMemoryKeyValueStore()
        let clock = TestClock("2026-11-25T23:30:00+01:00")
        _ = store(clock, storage: storage)
        let next = store(clock, storage: storage, enabled: false)
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(next.isAsleep)
        XCTAssertEqual(next.check("1234"), .accepted)
    }
}
