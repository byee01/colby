namespace Combustion.Core;

/// <summary>
/// Deadband filter for the Instant Read temperature.
/// Port of the Combustion Android SDK <c>InstantReadFilter</c>
/// (combustion-android-ble: <c>inc.combustion.framework.InstantReadFilter</c>, MIT, (c) 2023 Combustion Inc.),
/// so the number shown matches the phone app. Displayed value moves only when the raw reading leaves
/// <c>display ± (0.5 + 0.05 °C)</c> and then snaps to the nearest whole degree. Celsius and Fahrenheit are
/// filtered independently, each on whole degrees of its own unit, exactly as the SDK does. Null input clears.
/// </summary>
public struct InstantReadFilter
{
    /// <summary>SDK <c>DEADBAND_RANGE_IN_CELSIUS</c>.</summary>
    internal const double DeadbandCelsius = 0.05;

    public double? Celsius { get; private set; }

    public double? Fahrenheit { get; private set; }

    public void AddReading(double? temperatureC)
    {
        if (temperatureC is not { } t)
        {
            Celsius = null;
            Fahrenheit = null;
            return;
        }
        Celsius = Filtered(t, Celsius, DeadbandCelsius);
        Fahrenheit = Filtered(t * 9 / 5 + 32, Fahrenheit, DeadbandCelsius * 9 / 5);
    }

    private static double Filtered(double temperature, double? current, double deadband)
    {
        var display = current ?? RoundHalfUp(temperature);
        var upper = display + 0.5 + deadband;
        var lower = display - 0.5 - deadband;
        return temperature > upper || temperature < lower ? RoundHalfUp(temperature) : display;
    }

    /// <summary>Kotlin <c>roundToInt()</c> (Math.round): halves round toward +infinity.</summary>
    private static double RoundHalfUp(double v) => Math.Floor(v + 0.5);
}
