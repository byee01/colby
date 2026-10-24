import CombustionCodec
import CombustionCore
import Foundation
import Testing
@testable import ColbyUI

private let utc = TimeZone(identifier: "UTC")!
private let f = Formatter(unit: .fahrenheit, locale: Locale(identifier: "en_GB"), timeZone: utc)
private let c = Formatter(unit: .celsius, locale: Locale(identifier: "en_GB"), timeZone: utc)
private let serial = ProbeSerial(0x1000_D027)
private let noon = Date(timeIntervalSince1970: 1_799_971_200 + 12 * 3600) // 2027-01-15 12:00 UTC

private func view(_ state: PredictionState, seconds: UInt32? = nil, type: PredictionType = .removal,
                  stale: Bool = false, readyAt: Date? = nil, readySince: Date? = nil) -> PredictionView {
    PredictionView(serial: serial, state: state, mode: .timeToRemoval, type: type, setpoint: 63, estimatedCore: 40,
                   percentToRemoval: 50, secondsRemaining: seconds, isStale: stale, readyAt: readyAt, readySince: readySince)
}

struct FormatTests {
    @Test func temperaturesAreWholeDegreesInTheUserUnit() {
        #expect(f.temperature(95) == "203°")
        #expect(c.temperature(95) == "95°")
        #expect(c.temperature(-0.4) == "0°")
        #expect(f.temperature(nil) == "—")
        #expect(f.temperatureWithUnit(95) == "203°F")
    }

    @Test func instantReadHasOneDecimalDrawnSeparately() {
        #expect(f.instantRead(74.0).whole == "165")
        #expect(f.instantRead(74.0).fraction == ".2°")
        #expect(c.instantRead(-1.25).whole == "-1")
        #expect(c.instantRead(-1.25).fraction == ".3°")
    }

    @Test func countdownIsHoursAndMinutesRoundedUp() {
        #expect(f.countdown(0) == "0:00")
        #expect(f.countdown(1) == "0:01")
        #expect(f.countdown(222) == "0:04")
        #expect(f.countdown(3 * 3600 + 42 * 60) == "3:42")
        #expect(f.countdown(3 * 3600 + 41 * 60 + 1) == "3:42")
    }

    @Test func clockFollowsTheLocale() {
        #expect(c.clock(noon.addingTimeInterval(5 * 3600 + 120)) == "17:02")
        let us = Formatter(unit: .fahrenheit, locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(us.clock(noon.addingTimeInterval(5 * 3600 + 120)).hasPrefix("5:02"))
    }

    @Test func readyTextPerState() throws {
        let at = noon.addingTimeInterval(5 * 3600 + 120)
        let predicting = try #require(ReadyText(view(.predicting, seconds: 3 * 3600 + 42 * 60, readyAt: at), format: c))
        #expect(predicting == ReadyText(caption: "Ready in", primary: "3:42", secondary: "at 17:02"))
        let done = try #require(ReadyText(view(.removalPredictionDone, readySince: at), format: c))
        #expect(done == ReadyText(caption: "Remove now", primary: "Ready", secondary: "since 17:02", tone: .ready))
        #expect(ReadyText(view(.removalPredictionDone, type: .resting), format: c)?.caption == "Rested")
        #expect(ReadyText(view(.predicting, seconds: 60, stale: true), format: c)?.tone == .muted)
        #expect(ReadyText(view(.warming), format: c)?.caption == "Warming")
        #expect(ReadyText(view(.notInserted), format: c) == nil)
        #expect(ReadyText(nil, format: c) == nil)
    }

    @Test func unitDefaultsFromTheLocale() {
        #expect(TemperatureUnit.default(for: Locale(identifier: "en_US")) == .fahrenheit)
        #expect(TemperatureUnit.default(for: Locale(identifier: "en_GB")) == .celsius)
    }
}
