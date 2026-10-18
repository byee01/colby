using Combustion.Codec;

namespace Combustion.Core;

/// <summary>Where a probe's alert rules are kept between runs (the <c>alert_rule</c> table, docs/02 §11).</summary>
public interface IAlertRuleStore
{
    /// <summary>Null if the probe has never been configured (the engine then seeds the default set).</summary>
    Task<ValueList<AlertRule>?> LoadRulesAsync(ProbeSerial serial);

    Task SaveRulesAsync(ValueList<AlertRule> rules, ProbeSerial serial);
}

public sealed class InMemoryAlertRuleStore : IAlertRuleStore
{
    private readonly Dictionary<ProbeSerial, ValueList<AlertRule>> _stored = [];

    public Task<ValueList<AlertRule>?> LoadRulesAsync(ProbeSerial serial) =>
        Task.FromResult(_stored.GetValueOrDefault(serial));

    public Task SaveRulesAsync(ValueList<AlertRule> rules, ProbeSerial serial)
    {
        _stored[serial] = rules;
        return Task.CompletedTask;
    }
}

/// <summary>One timestamped core reading, for the stall rule.</summary>
internal readonly record struct CoreSample(DateTimeOffset Time, double Celsius);

/// <summary>What a rule sees when evaluated.</summary>
/// <param name="WasActive">The alert for this rule is currently firing, acknowledged or snoozed (selects the clear side of hysteresis).</param>
/// <param name="CookActive">The probe was in a cook when it last had data.</param>
internal sealed record RuleInput(
    ProbeSnapshot Snapshot,
    PredictionView? Prediction,
    DateTimeOffset Now,
    bool WasActive,
    bool CookActive,
    IReadOnlyList<CoreSample> CoreHistory);

/// <summary>Outcome of evaluating one rule.</summary>
/// <param name="Met">The condition holds right now.</param>
/// <param name="Since">Start of the quiet period, if the rule knows it (offline: the last data). Null: since first seen met.</param>
internal readonly record struct RuleOutcome(bool Met, double? Value, DateTimeOffset? Since = null);

/// <summary>Pure rule logic: snapshot (+ prediction view) in, outcome out. Null means "cannot tell right now" (missing
/// data, stale prediction): the alert keeps whatever state it has.</summary>
internal static class RuleEvaluator
{
    /// <summary>One quantum of the prediction countdown (rounded to 15 s); keeps <c>PredictionWithin</c> from flapping.</summary>
    public const int PredictionHysteresis = 15;

    /// <summary>Without a prediction, a core above this is taken as "in food on the heat".</summary>
    public const double HotCoreCelsius = 40.0;

    public static RuleOutcome? Evaluate(AlertRuleKind kind, RuleInput i)
    {
        switch (kind)
        {
            case AlertRuleKind.TemperatureAbove r:
            {
                if (Temperature(r.Channel, i.Snapshot) is not { } t)
                {
                    return null;
                }
                return new RuleOutcome(i.WasActive ? t >= r.Celsius - r.Hysteresis : t >= r.Celsius, t);
            }
            case AlertRuleKind.TemperatureBelow r:
            {
                if (Temperature(r.Channel, i.Snapshot) is not { } t)
                {
                    return null;
                }
                return new RuleOutcome(i.WasActive ? t <= r.Celsius + r.Hysteresis : t <= r.Celsius, t);
            }
            case AlertRuleKind.PredictionWithin r:
            {
                if (i.Prediction is not { IsStale: false } p)
                {
                    return null;
                }
                if (p.SecondsRemaining is not { } left)
                {
                    return new RuleOutcome(false, null);
                }
                var limit = i.WasActive ? r.Seconds + PredictionHysteresis : r.Seconds;
                return new RuleOutcome(left <= limit, left);
            }
            case AlertRuleKind.PredictionDone:
            {
                if (i.Prediction is not { } p)
                {
                    return null;
                }
                return new RuleOutcome(p.State == PredictionState.RemovalPredictionDone && p.Type != PredictionType.Resting, null);
            }
            case AlertRuleKind.RestingDone:
            {
                if (i.Prediction is not { } p)
                {
                    return null;
                }
                var done = p.Type == PredictionType.Resting
                    && (p.State == PredictionState.RemovalPredictionDone || (p.State == PredictionState.Predicting && p.SecondsRemaining == 0));
                return new RuleOutcome(done, null);
            }
            case AlertRuleKind.AmbientOutOfRange r:
            {
                if (i.Snapshot.Mode != ProbeMode.Normal || i.Snapshot.Virtual.Ambient is not { } ambient)
                {
                    return null;
                }
                return new RuleOutcome(ambient < r.Min || ambient > r.Max, ambient);
            }
            case AlertRuleKind.Stall r:
            {
                if (i.Snapshot.Virtual.Core is not { } core)
                {
                    return null;
                }
                var predicting = (i.Prediction?.State ?? i.Snapshot.Prediction?.State) == PredictionState.Predicting;
                if (!predicting)
                {
                    return new RuleOutcome(false, null);
                }
                // Compare with the newest reading that is at least `window` old; with none, the window is not covered yet.
                CoreSample? reference = null;
                for (var k = i.CoreHistory.Count - 1; k >= 0; k--)
                {
                    if (i.Now.Since(i.CoreHistory[k].Time) >= r.Window - 1)
                    {
                        reference = i.CoreHistory[k];
                        break;
                    }
                }
                if (reference is not { } refSample)
                {
                    return new RuleOutcome(false, null);
                }
                var rise = core - refSample.Celsius;
                return new RuleOutcome(rise < r.MinRise, rise);
            }
            case AlertRuleKind.ProbeOffline r:
            {
                if (!i.Snapshot.IsOffline)
                {
                    return new RuleOutcome(false, null);
                }
                return new RuleOutcome(!r.OnlyDuringCook || i.CookActive, null, i.Snapshot.ReceivedAt);
            }
            case AlertRuleKind.BatteryLow:
                return new RuleOutcome(i.Snapshot.BatteryLow, null);
            default:
                return null;
        }
    }

    /// <summary>The reading a channel stands for. Instant Read leaves only T1 valid, so the others are null there.</summary>
    public static double? Temperature(AlarmChannel channel, ProbeSnapshot s)
    {
        switch (channel)
        {
            case AlarmChannel.Core:
                return s.Virtual.Core;
            case AlarmChannel.Surface:
                return s.Virtual.Surface;
            case AlarmChannel.Ambient:
                return s.Virtual.Ambient;
            default:
                var i = (int)channel;
                return i >= 0 && i < s.Temperatures.Count ? s.Temperatures[i] : null;
        }
    }

    /// <summary>A probe counts as cooking when it is out of Instant Read and either has a prediction under way or is
    /// clearly hot. Used for keep-awake and for <c>ProbeOffline(OnlyDuringCook)</c>.</summary>
    public static bool IsCooking(ProbeSnapshot s)
    {
        if (s.Mode != ProbeMode.Normal)
        {
            return false;
        }
        return s.Prediction?.State switch
        {
            PredictionState.Inserted or PredictionState.Warming or PredictionState.Predicting or PredictionState.RemovalPredictionDone => true,
            _ => (s.Virtual.Core ?? 0) >= HotCoreCelsius,
        };
    }
}
