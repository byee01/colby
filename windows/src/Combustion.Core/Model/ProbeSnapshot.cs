using Combustion.Codec;

namespace Combustion.Core;

/// <summary>Virtual sensor selection plus the temperatures it resolves to. docs/02 §3 <c>virtual</c>.
/// Temperatures are null when the underlying sensor has no value (Instant Read except T1).</summary>
public sealed record VirtualTemps(
    SensorIndex CoreSensor,
    SensorIndex SurfaceSensor,
    SensorIndex AmbientSensor,
    double? Core,
    double? Surface,
    double? Ambient);

/// <summary>Session fields of a full status. <c>Info</c> is null when the probe reports session ID 0 (old firmware or old node).</summary>
public sealed record ProbeSessionState(SessionInfo? Info, LogRange LogRange);

/// <summary>Everything the UI knows about one probe, merged from all sources. docs/02 §3.</summary>
/// <param name="Temperatures">T1...T8 in °C. In Instant Read mode only T1 is non-null.</param>
/// <param name="InstantRead">Filtered Instant Read temperature (°C); only in <c>InstantRead</c> mode.</param>
/// <param name="InstantReadFahrenheit">The same reading filtered on a whole-°F deadband (Android SDK computes both); for °F displays.</param>
/// <param name="Prediction">Null if only advertisement data has been seen.</param>
/// <param name="Alarms">Null until a full status has been received.</param>
/// <param name="Session">Null until a full status has been received.</param>
public sealed record ProbeSnapshot(
    ProbeSerial Serial,
    int ProbeNumber,
    ProbeColor Color,
    ProbeMode Mode,
    ValueList<double?> Temperatures,
    VirtualTemps Virtual,
    bool BatteryLow,
    LinkInfo Link,
    DateTimeOffset ReceivedAt,
    double? InstantRead = null,
    double? InstantReadFahrenheit = null,
    SensorSet Overheating = default,
    PredictionStatus? Prediction = null,
    AlarmConfig? Alarms = null,
    FoodSafe? FoodSafe = null,
    ProbeSessionState? Session = null)
{
    /// <summary>True when no source is currently delivering data.</summary>
    public bool IsOffline => Link.Sources.Count == 0;
}

/// <summary>A full status accepted by <c>ProbeStore</c>, for <c>HistoryStore</c> and session detection.</summary>
public sealed record ProbeStatusEvent(ProbeSerial Serial, ProbeStatusPayload Status, DateTimeOffset ReceivedAt);
