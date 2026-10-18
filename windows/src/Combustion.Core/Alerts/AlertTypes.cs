using Combustion.Codec;

namespace Combustion.Core;

/// <summary>The app-side alert rules of v1. docs/02 §9.</summary>
public abstract record AlertRuleKind
{
    private AlertRuleKind() { }

    /// <summary>Fires when the channel reaches <c>Celsius</c>; clears below <c>Celsius - Hysteresis</c>.</summary>
    public sealed record TemperatureAbove(AlarmChannel Channel, double Celsius, double Hysteresis = 1) : AlertRuleKind;

    /// <summary>Fires when the channel falls to <c>Celsius</c>; clears above <c>Celsius + Hysteresis</c>.</summary>
    public sealed record TemperatureBelow(AlarmChannel Channel, double Celsius, double Hysteresis = 1) : AlertRuleKind;

    /// <summary>Fires when the countdown is at or under <c>Seconds</c>.</summary>
    public sealed record PredictionWithin(int Seconds) : AlertRuleKind;

    /// <summary>Fires when the removal prediction is done. Stays firing until acknowledged.</summary>
    public sealed record PredictionDone : AlertRuleKind;

    /// <summary>Fires when the resting prediction reaches 0. Stays firing until acknowledged.</summary>
    public sealed record RestingDone : AlertRuleKind;

    /// <summary>Ambient outside <c>Min...Max</c> for <c>Sustain</c> seconds.</summary>
    public sealed record AmbientOutOfRange(double Min, double Max, double Sustain) : AlertRuleKind;

    /// <summary>While predicting, the core rose by less than <c>MinRise</c> °C over <c>Window</c> seconds.</summary>
    public sealed record Stall(double Window, double MinRise) : AlertRuleKind
    {
        /// <summary>The default 30-minute window.</summary>
        public Stall(double minRise)
            : this(1800, minRise)
        {
        }
    }

    /// <summary>No source delivered data for <c>Seconds</c>. With <c>OnlyDuringCook</c> it fires only if the probe was
    /// in a cook when it went quiet (the default alert set uses this, 06 §6).</summary>
    public sealed record ProbeOffline(double Seconds = 60, bool OnlyDuringCook = false) : AlertRuleKind;

    public sealed record BatteryLow : AlertRuleKind;

    /// <summary>How long the condition must hold, uninterrupted, before the alert fires.</summary>
    internal double SustainSeconds => this switch
    {
        AmbientOutOfRange a => a.Sustain,
        ProbeOffline o => o.Seconds,
        _ => 0,
    };

    /// <summary>Event-like rules: once fired they stay until acknowledged, even if the condition goes away
    /// ("Ready" repeats until acknowledged, 06 §6).</summary>
    internal bool LatchesUntilAcknowledged => this is PredictionDone or RestingDone;
}

public sealed record AlertRule(string Id, AlertRuleKind Kind, bool Enabled = true)
{
    /// <summary>A rule with a new random id (Swift <c>UUID().uuidString</c>).</summary>
    public AlertRule(AlertRuleKind kind, bool enabled = true)
        : this(Guid.NewGuid().ToString().ToUpperInvariant(), kind, enabled)
    {
    }

    /// <summary>The alert set a probe gets when first followed (06 §6): Ready, 5-minute warning, Disconnected (only
    /// during a cook), Low battery. Overheat and probe alarms are always on and are not rules.</summary>
    public static ValueList<AlertRule> Defaults(ProbeSerial serial) =>
    [
        new($"{serial.Hex}.ready", new AlertRuleKind.PredictionDone()),
        new($"{serial.Hex}.fiveMinutes", new AlertRuleKind.PredictionWithin(300)),
        new($"{serial.Hex}.offline", new AlertRuleKind.ProbeOffline(60, OnlyDuringCook: true)),
        new($"{serial.Hex}.battery", new AlertRuleKind.BatteryLow()),
    ];
}

/// <summary>Where an alert comes from.</summary>
public abstract record AlertSource
{
    private AlertSource() { }

    public sealed record Rule(AlertRuleKind Kind) : AlertSource;

    /// <summary>A probe alarm whose <c>Alarming</c> bit is set. Acknowledging it silences the probe (0x0C).</summary>
    public sealed record ProbeAlarm(AlarmKind Kind, AlarmChannel Channel) : AlertSource;

    /// <summary>The probe's overheat bit for a sensor. Cannot be silenced on the probe.</summary>
    public sealed record Overheat(SensorIndex Sensor) : AlertSource;
}

/// <summary>Sort order when several fire: overheat &gt; probe alarms &gt; prediction done &gt; everything else (06 §7).</summary>
public enum AlertPriority { Other, PredictionDone, ProbeAlarm, Overheat }

/// <summary>docs/02 §9 state machine. <c>Idle</c> is never stored in the active list; it appears as the start or end of an event.</summary>
public enum AlertState { Idle, Firing, Acknowledged, Snoozed }

public static class AlertStateNames
{
    /// <summary>Lower-case name, as in the parity trace.</summary>
    public static string Name(this AlertState state) => state switch
    {
        AlertState.Idle => "idle",
        AlertState.Firing => "firing",
        AlertState.Acknowledged => "acknowledged",
        _ => "snoozed",
    };
}

/// <summary>The sound a sink should play for an alert (06 §17.3: Ready, Overheat and probe alarms each have their own).</summary>
public enum AlertSound { Ready, Overheat, ProbeAlarm, Alert }

/// <param name="Id">A rule's id for rule alerts; <c>&lt;serial&gt;.alarm.&lt;high|low&gt;.&lt;channel&gt;</c> and
/// <c>&lt;serial&gt;.overheat.&lt;sensor&gt;</c> otherwise.</param>
/// <param name="Value">The reading that tripped it (°C for temperatures, seconds for countdowns), latest while firing.</param>
public sealed record AlertInstance(
    string Id,
    ProbeSerial Serial,
    AlertSource Source,
    AlertState State,
    DateTimeOffset FiredAt,
    DateTimeOffset? AcknowledgedAt = null,
    DateTimeOffset? SnoozedUntil = null,
    double? Value = null)
{
    public AlertPriority Priority => Source switch
    {
        AlertSource.Overheat => AlertPriority.Overheat,
        AlertSource.ProbeAlarm => AlertPriority.ProbeAlarm,
        AlertSource.Rule { Kind: AlertRuleKind.PredictionDone or AlertRuleKind.RestingDone } => AlertPriority.PredictionDone,
        _ => AlertPriority.Other,
    };

    public AlertSound Sound => Source switch
    {
        AlertSource.Overheat => AlertSound.Overheat,
        AlertSource.ProbeAlarm => AlertSound.ProbeAlarm,
        AlertSource.Rule { Kind: AlertRuleKind.PredictionDone or AlertRuleKind.RestingDone } => AlertSound.Ready,
        _ => AlertSound.Alert,
    };
}

/// <summary>One state change of an alert. <c>Instance</c> is the alert after the change (state <c>Idle</c> when it cleared).</summary>
/// <param name="Failure">Set when a probe silence failed and the alert went back to firing.</param>
public sealed record AlertEvent(AlertInstance Instance, AlertState From, AlertState To, DateTimeOffset At, string? Failure = null)
{
    /// <summary><c>"idle-&gt;firing"</c>, as in the parity trace (docs/05 §3).</summary>
    public string Transition => $"{From.Name()}->{To.Name()}";
}
