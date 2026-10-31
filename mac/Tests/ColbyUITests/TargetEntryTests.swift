#if canImport(SwiftUI) && canImport(AppKit)
import CombustionCodec
import CombustionCore
import Testing
@testable import ColbyUI

struct TargetEntryTests {
    @Test func fahrenheitIsSentAsCelsiusToATenth() {
        #expect(TargetEntry.parse("203", unit: .fahrenheit) == .success(95))
        #expect(TargetEntry.parse(" 145 ", unit: .fahrenheit) == .success(62.8))
        #expect(TargetEntry.parse("63,5", unit: .celsius) == .success(63.5))
    }

    @Test func theProbesRangeIsEnforced() {
        #expect(TargetEntry.parse("32", unit: .fahrenheit) == .success(0))
        #expect(TargetEntry.parse("216", unit: .fahrenheit) == .success(102.2))
        #expect(TargetEntry.parse("217", unit: .fahrenheit) == .failure(.outOfRange))
        #expect(TargetEntry.parse("102.3", unit: .celsius) == .success(maxPredictionSetpoint))
        #expect(TargetEntry.parse("102.4", unit: .celsius) == .failure(.outOfRange))
        #expect(TargetEntry.parse("31", unit: .fahrenheit) == .failure(.outOfRange))
        #expect(TargetEntry.parse("", unit: .celsius) == .failure(.empty))
        #expect(TargetEntry.parse("hot", unit: .celsius) == .failure(.notANumber))
        #expect(TargetEntry.parse("inf", unit: .celsius) == .failure(.notANumber))
    }

    @Test func helpShowsTheRangeInTheUsersUnit() {
        #expect(TargetEntry.range(.fahrenheit) == "32–216°F")
        #expect(TargetEntry.range(.celsius) == "0–102°C")
        #expect(TargetEntry.help(nil, unit: .fahrenheit) == "Range 32–216°F")
        #expect(TargetEntry.help(.outOfRange, unit: .celsius) == "The probe takes 0–102°C.")
        #expect(TargetEntry.text(95, unit: .fahrenheit) == "203")
    }

    @Test func commandFailuresReadAsSentences() {
        #expect(commandFailureText(CommandError.notConfirmed) == "The probe didn't confirm.")
        #expect(commandFailureText(CommandError.notReachable).hasPrefix("The probe isn't connected"))
    }
}
#endif
