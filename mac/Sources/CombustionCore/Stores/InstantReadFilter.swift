import Foundation

/// Deadband filter for the Instant Read temperature.
///
/// Port of the Combustion Android SDK `InstantReadFilter`
/// (combustion-android-ble: `inc.combustion.framework.InstantReadFilter`, MIT, (c) 2023 Combustion Inc.),
/// so the number shown matches the phone app. Displayed value moves only when the raw reading leaves
/// `display ± (0.5 + 0.05 °C)` and then snaps to the nearest whole degree. Celsius and Fahrenheit are
/// filtered independently, each on whole degrees of its own unit, exactly as the SDK does. `nil` input clears.
public struct InstantReadFilter: Sendable, Equatable {
    /// SDK `DEADBAND_RANGE_IN_CELSIUS`.
    static let deadbandCelsius = 0.05

    public private(set) var celsius: Double?
    public private(set) var fahrenheit: Double?

    public init() {}

    public mutating func addReading(_ temperatureC: Double?) {
        guard let t = temperatureC else {
            celsius = nil
            fahrenheit = nil
            return
        }
        celsius = Self.filtered(t, current: celsius, deadband: Self.deadbandCelsius)
        fahrenheit = Self.filtered(t * 9 / 5 + 32, current: fahrenheit, deadband: Self.deadbandCelsius * 9 / 5)
    }

    private static func filtered(_ temperature: Double, current: Double?, deadband: Double) -> Double {
        let display = current ?? roundHalfUp(temperature)
        let upper = display + 0.5 + deadband
        let lower = display - 0.5 - deadband
        if temperature > upper || temperature < lower { return roundHalfUp(temperature) }
        return display
    }

    /// Kotlin `roundToInt()` (Math.round): halves round toward +infinity.
    private static func roundHalfUp(_ v: Double) -> Double { (v + 0.5).rounded(.down) }
}
