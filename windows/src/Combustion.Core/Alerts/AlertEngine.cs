using Combustion.Codec;

namespace Combustion.Core;

/// <summary>
/// Rules, probe alarms and overheat in one pipeline, with acknowledge, snooze and keep-awake. docs/02 §9.
/// <para>Inputs: probe snapshots, prediction views and the followed set (<see cref="Start"/> subscribes; tests may call
/// <c>IngestAsync</c> and <see cref="SetFollowedAsync"/> directly). Only followed probes are evaluated.</para>
/// <code>
/// idle ──condition true──▶ firing ──ack──▶ acknowledged ──condition false──▶ idle
///                            │ └─snooze──▶ snoozed ──timer──▶ firing (if still true)
///                            └─condition false (auto-clear)──▶ idle
/// </code>
/// <list type="bullet">
/// <item>A rule fires once per crossing; it re-arms only after it clears (hysteresis keeps a reading that hovers at
/// the threshold from flapping). Rules with a sustain time (<c>AmbientOutOfRange</c>, <c>ProbeOffline</c>) fire when
/// the condition has held that long, measured on the <see cref="IClock"/>.</item>
/// <item><c>PredictionDone</c> and <c>RestingDone</c> latch: they stay firing after the condition is gone, until acknowledged.</item>
/// <item>A probe alarm (<c>Alarming</c> bit) is acknowledged by sending Silence Alarms to the probe. The app mutes
/// locally at once and goes back to firing, with a <c>Failure</c> on the event, if the probe could not be silenced.
/// Overheat cannot be silenced on the probe; acknowledging it only mutes the app.</item>
/// <item>A probe that has no source is not evaluated for alarms or overheat (they clear); <c>ProbeOffline</c> covers it.</item>
/// <item>Keep-awake is held while any followed probe is in a cook (<see cref="RuleEvaluator.IsCooking"/>). A cook that
/// goes quiet counts for <c>cookIdleTimeout</c>, so the computer stays awake while the app tries to reconnect.</item>
/// </list>
/// Sinks get events in order, one at a time, after the state change is complete. Confined to the core context (Swift: actor).
/// </summary>
public sealed class AlertEngine
{
    public static readonly TimeSpan CookIdleTimeout = TimeSpan.FromSeconds(600);

    /// <summary>Pass as <c>defaultRules</c> to seed nothing (Swift: <c>defaultRules: nil</c>).</summary>
    public static readonly Func<ProbeSerial, ValueList<AlertRule>> NoDefaultRules = _ => [];

    /// <summary>A condition that holds but has not held long enough.</summary>
    private readonly record struct Pending(DateTimeOffset Since, double Sustain)
    {
        public DateTimeOffset Deadline => Since.AddSecondsExact(Sustain);
    }

    /// <summary>What one evaluation wants for one alert id.</summary>
    private readonly record struct Desired(AlertSource Source, RuleOutcome Outcome, double Sustain, bool Latch);

    private sealed class CookState
    {
        public bool Active { get; set; }

        public DateTimeOffset? LastActive { get; set; }
    }

    private abstract record Outgoing
    {
        public sealed record Event(AlertEvent Value) : Outgoing;

        public sealed record KeepAwake(bool On) : Outgoing;
    }

    /// <summary>Slack for comparing deadlines that went through floating-point seconds.</summary>
    private const double Epsilon = 0.001;

    /// <summary>Core history for the stall rule: at least this much, and a minute more than the longest window.</summary>
    private const double MinHistory = 3600;

    private const double HistoryStep = 4.9;

    private readonly IClock _clock;
    private readonly IAlertRuleStore _ruleStore;
    private readonly IReadOnlyList<IAlertSink> _sinks;
    private readonly IKeepAwake? _keepAwake;
    private readonly IProbeAlarmSilencing? _silencer;
    private readonly ITraceSink? _trace;
    private readonly Func<ProbeSerial, ValueList<AlertRule>>? _defaultRules;
    private readonly double _cookIdle;

    private readonly Broadcaster<AlertEvent> _events = new();
    private readonly Broadcaster<ValueList<AlertInstance>> _active = new(ValueList<AlertInstance>.Empty, replayLatest: true);

    private HashSet<ProbeSerial> _followed = [];
    private readonly Dictionary<ProbeSerial, ValueList<AlertRule>> _ruleSets = [];
    private readonly Dictionary<ProbeSerial, ProbeSnapshot> _snapshots = [];
    private readonly Dictionary<ProbeSerial, PredictionView> _views = [];
    private readonly Dictionary<string, AlertInstance> _instances = [];
    private readonly Dictionary<string, Pending> _pending = [];
    private readonly Dictionary<ProbeSerial, List<CoreSample>> _history = [];
    private readonly Dictionary<ProbeSerial, CookState> _cooks = [];
    private bool _held;

    private readonly Queue<Outgoing> _outbox = new();
    private bool _draining;
    private CancellationTokenSource? _wake;
    private CancellationTokenSource? _inputs;

    /// <param name="defaultRules">The set seeded for a probe that has never had rules; null means
    /// <see cref="AlertRule.Defaults"/>, <see cref="NoDefaultRules"/> seeds nothing.</param>
    public AlertEngine(
        IClock clock,
        IAlertRuleStore? ruleStore = null,
        IReadOnlyList<IAlertSink>? sinks = null,
        IKeepAwake? keepAwake = null,
        IProbeAlarmSilencing? silencer = null,
        ITraceSink? trace = null,
        Func<ProbeSerial, ValueList<AlertRule>>? defaultRules = null,
        TimeSpan? cookIdleTimeout = null)
    {
        _clock = clock;
        _ruleStore = ruleStore ?? new InMemoryAlertRuleStore();
        _sinks = sinks ?? [];
        _keepAwake = keepAwake;
        _silencer = silencer;
        _trace = trace;
        _defaultRules = ReferenceEquals(defaultRules, NoDefaultRules) ? null : defaultRules ?? AlertRule.Defaults;
        _cookIdle = (cookIdleTimeout ?? CookIdleTimeout).TotalSeconds;
    }

    // Observables

    /// <summary>Every state change, in order.</summary>
    public AsyncStream<AlertEvent> Events() => _events.Stream();

    /// <summary>Alerts that are firing, acknowledged or snoozed, most urgent first; the latest list first, then changes.</summary>
    public AsyncStream<ValueList<AlertInstance>> Active() => _active.Stream();

    /// <summary>Right now, most urgent first (overheat &gt; probe alarms &gt; prediction done &gt; others; newest first within a level).</summary>
    public ValueList<AlertInstance> ActiveAlerts() => SortedActive();

    // Lifecycle

    /// <summary>Subscribes to the inputs. Call once; the streams are consumed until <see cref="StopAsync"/>.</summary>
    public void Start(
        IAsyncEnumerable<IReadOnlyDictionary<ProbeSerial, ProbeSnapshot>> probes,
        IAsyncEnumerable<PredictionUpdate> predictions,
        IAsyncEnumerable<IReadOnlySet<ProbeSerial>> followed)
    {
        if (_inputs is not null)
        {
            return;
        }
        _inputs = new CancellationTokenSource();
        var ct = _inputs.Token;
        _ = Consume(probes, IngestAsync, ct);
        _ = Consume(predictions, u => IngestAsync(u.View), ct);
        _ = Consume(followed, SetFollowedAsync, ct);
    }

    private static async Task Consume<T>(IAsyncEnumerable<T> source, Func<T, Task> body, CancellationToken ct)
    {
        try
        {
            await foreach (var item in source.WithCancellation(ct))
            {
                await body(item);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }

    /// <summary>Stops listening and timing, releases keep-awake. Alerts stay as they are.</summary>
    public async Task StopAsync()
    {
        _inputs?.Cancel();
        _inputs = null;
        _wake?.Cancel();
        _wake = null;
        if (_held)
        {
            _held = false;
            if (_keepAwake is not null)
            {
                await _keepAwake.SetHeldAsync(false);
            }
        }
    }

    // Rules

    public async Task<ValueList<AlertRule>> RulesAsync(ProbeSerial serial)
    {
        await LoadRulesAsync(serial);
        return _ruleSets.GetValueOrDefault(serial) ?? ValueList<AlertRule>.Empty;
    }

    public async Task AddRuleAsync(ProbeSerial serial, AlertRule rule)
    {
        await LoadRulesAsync(serial);
        var rules = (_ruleSets.GetValueOrDefault(serial) ?? ValueList<AlertRule>.Empty).Where(r => r.Id != rule.Id).ToList();
        rules.Add(rule);
        await ChangedAsync(serial, rules);
    }

    /// <summary>Replaces the rule with the same id. Changing the kind or disabling it clears its alert.</summary>
    public async Task UpdateRuleAsync(ProbeSerial serial, AlertRule rule)
    {
        await LoadRulesAsync(serial);
        var rules = (_ruleSets.GetValueOrDefault(serial) ?? ValueList<AlertRule>.Empty).ToList();
        var i = rules.FindIndex(r => r.Id == rule.Id);
        if (i < 0)
        {
            return;
        }
        if (rules[i].Kind != rule.Kind)
        {
            Forget(rule.Id);
        }
        rules[i] = rule;
        await ChangedAsync(serial, rules);
    }

    public async Task RemoveRuleAsync(ProbeSerial serial, string id)
    {
        await LoadRulesAsync(serial);
        var rules = (_ruleSets.GetValueOrDefault(serial) ?? ValueList<AlertRule>.Empty).Where(r => r.Id != id).ToList();
        await ChangedAsync(serial, rules);
    }

    // Acknowledge, snooze, silence

    /// <summary>Stops the sound and keeps the alert in the active list until its condition clears. A probe alarm also
    /// silences the probe (and so its Display and phone).</summary>
    public async Task AcknowledgeAsync(string id)
    {
        if (!_instances.TryGetValue(id, out var t) || t.State is not (AlertState.Firing or AlertState.Snoozed))
        {
            return;
        }
        Transition(id, AlertState.Acknowledged, _clock.Now());
        await DrainOutboxAsync();
        if (t.Source is AlertSource.ProbeAlarm)
        {
            await SilenceProbeAsync(t.Serial, [id]);
        }
    }

    /// <summary>Mutes a firing alert for <paramref name="duration"/>; it fires again then if the condition still
    /// holds. Local only: a probe alarm keeps sounding on the probe.</summary>
    public async Task SnoozeAsync(string id, TimeSpan duration)
    {
        if (!_instances.TryGetValue(id, out var t) || t.State != AlertState.Firing)
        {
            return;
        }
        var now = _clock.Now();
        _instances[id] = t with { SnoozedUntil = now.AddSecondsExact(duration.TotalSeconds) };
        Transition(id, AlertState.Snoozed, now);
        ScheduleWake();
        await DrainOutboxAsync();
    }

    /// <summary>Acknowledges everything firing for the probe; sends one Silence Alarms if any probe alarm was among them.</summary>
    public async Task SilenceAllAsync(ProbeSerial serial)
    {
        var now = _clock.Now();
        var mine = _instances.Values
            .Where(a => a.Serial == serial && a.State is AlertState.Firing or AlertState.Snoozed)
            .ToList();
        foreach (var a in mine)
        {
            Transition(a.Id, AlertState.Acknowledged, now);
        }
        await DrainOutboxAsync();
        var probeAlarms = mine.Where(a => a.Source is AlertSource.ProbeAlarm).Select(a => a.Id).ToList();
        if (probeAlarms.Count > 0)
        {
            await SilenceProbeAsync(serial, probeAlarms);
        }
    }

    private async Task SilenceProbeAsync(ProbeSerial serial, IReadOnlyList<string> ids)
    {
        if (_silencer is null)
        {
            return;
        }
        try
        {
            await _silencer.SilenceAlarmsAsync(serial);
        }
        catch (Exception error)
        {
            // The probe is still alarming: the app must not stay quiet about it.
            var now = _clock.Now();
            foreach (var id in ids)
            {
                if (_instances.TryGetValue(id, out var a) && a.State == AlertState.Acknowledged)
                {
                    Transition(id, AlertState.Firing, now, error.Message);
                }
            }
            await DrainOutboxAsync();
        }
    }

    // Inputs

    public async Task SetFollowedAsync(IReadOnlySet<ProbeSerial> set)
    {
        var added = set.Where(s => !_followed.Contains(s)).Order().ToList();
        var removed = _followed.Where(s => !set.Contains(s)).ToList();
        _followed = [.. set];
        foreach (var serial in removed)
        {
            DropProbe(serial);
        }
        foreach (var serial in added)
        {
            await LoadRulesAsync(serial, seed: true);
        }
        foreach (var serial in added)
        {
            Evaluate(serial);
        }
        FinishRound();
        await DrainOutboxAsync();
    }

    public async Task IngestAsync(IReadOnlyDictionary<ProbeSerial, ProbeSnapshot> map)
    {
        foreach (var (serial, snap) in map)
        {
            if (_snapshots.TryGetValue(serial, out var known) && known == snap)
            {
                continue;
            }
            _snapshots[serial] = snap;
            RecordCore(serial, snap);
            Evaluate(serial);
        }
        FinishRound();
        await DrainOutboxAsync();
    }

    public Task IngestAsync(ProbeSnapshot snap) =>
        IngestAsync(new Dictionary<ProbeSerial, ProbeSnapshot> { [snap.Serial] = snap });

    public async Task IngestAsync(PredictionView view)
    {
        if (_views.TryGetValue(view.Serial, out var known) && known == view)
        {
            return;
        }
        _views[view.Serial] = view;
        Evaluate(view.Serial);
        FinishRound();
        await DrainOutboxAsync();
    }

    // Rule storage

    /// <summary>Makes sure the probe's rules are in memory; with <paramref name="seed"/>, a never-configured probe gets the default set.</summary>
    private async Task LoadRulesAsync(ProbeSerial serial, bool seed = false)
    {
        if (_ruleSets.ContainsKey(serial))
        {
            return;
        }
        if (await _ruleStore.LoadRulesAsync(serial) is { } stored)
        {
            _ruleSets[serial] = stored;
        }
        else if (seed && _defaultRules is { } defaults)
        {
            var rules = defaults(serial);
            _ruleSets[serial] = rules;
            await _ruleStore.SaveRulesAsync(rules, serial);
        }
        else
        {
            _ruleSets.TryAdd(serial, ValueList<AlertRule>.Empty);
        }
    }

    private async Task ChangedAsync(ProbeSerial serial, List<AlertRule> list)
    {
        var rules = new ValueList<AlertRule>(list);
        _ruleSets[serial] = rules;
        await _ruleStore.SaveRulesAsync(rules, serial);
        Evaluate(serial);
        FinishRound();
        await DrainOutboxAsync();
    }

    private void Forget(string id)
    {
        if (!_instances.ContainsKey(id))
        {
            return;
        }
        Transition(id, AlertState.Idle, _clock.Now());
        _pending.Remove(id);
    }

    // Evaluation

    private void RecordCore(ProbeSerial serial, ProbeSnapshot snap)
    {
        if (snap.IsOffline || snap.Virtual.Core is not { } core)
        {
            return;
        }
        var now = _clock.Now();
        if (!_history.TryGetValue(serial, out var samples))
        {
            samples = [];
            _history[serial] = samples;
        }
        if (samples.Count > 0 && now.Since(samples[^1].Time) < HistoryStep)
        {
            return;
        }
        samples.Add(new CoreSample(now, core));
        var longest = (_ruleSets.GetValueOrDefault(serial) ?? ValueList<AlertRule>.Empty)
            .Select(r => r.Kind is AlertRuleKind.Stall s ? s.Window : 0)
            .DefaultIfEmpty(0)
            .Max();
        var keep = Math.Max(MinHistory, longest + 60);
        // Keep one sample older than the span: it is the reference for a window that exactly fills it.
        var firstInSpan = samples.FindIndex(s => now.Since(s.Time) <= keep);
        if (firstInSpan > 1)
        {
            samples.RemoveRange(0, firstInSpan - 1);
        }
    }

    private void Evaluate(ProbeSerial serial)
    {
        if (!_followed.Contains(serial))
        {
            return;
        }
        var now = _clock.Now();
        if (!_snapshots.TryGetValue(serial, out var snap))
        {
            return;
        }
        UpdateCook(serial, snap, now);

        var desired = new Dictionary<string, Desired>();
        var unknown = new HashSet<string>();

        foreach (var rule in _ruleSets.GetValueOrDefault(serial) ?? ValueList<AlertRule>.Empty)
        {
            if (!rule.Enabled)
            {
                continue;
            }
            var input = new RuleInput(
                snap, _views.GetValueOrDefault(serial), now, _instances.ContainsKey(rule.Id),
                _cooks.GetValueOrDefault(serial)?.Active ?? false,
                (IReadOnlyList<CoreSample>?)_history.GetValueOrDefault(serial) ?? []);
            if (RuleEvaluator.Evaluate(rule.Kind, input) is { } outcome)
            {
                desired[rule.Id] = new Desired(new AlertSource.Rule(rule.Kind), outcome, rule.Kind.SustainSeconds, rule.Kind.LatchesUntilAcknowledged);
            }
            else
            {
                unknown.Add(rule.Id);
            }
        }

        // Probe alarms and overheat come from the probe's own status; without a source they say nothing current.
        var online = !snap.IsOffline;
        if (snap.Alarms is { } alarms)
        {
            foreach (var (kind, set) in new[] { (AlarmKind.High, alarms.High), (AlarmKind.Low, alarms.Low) })
            {
                foreach (var channel in Enum.GetValues<AlarmChannel>())
                {
                    if (!online || !set.TryGetValue(channel, out var alarm) || !alarm.Alarming)
                    {
                        continue;
                    }
                    desired[AlarmId(serial, kind, channel)] = new Desired(
                        new AlertSource.ProbeAlarm(kind, channel), new RuleOutcome(true, alarm.Temperature), 0, false);
                }
            }
        }
        else
        {
            // No full status yet: nothing to clear, nothing to fire.
            foreach (var (id, a) in _instances)
            {
                if (a.Serial == serial && a.Source is AlertSource.ProbeAlarm)
                {
                    unknown.Add(id);
                }
            }
        }
        if (online)
        {
            foreach (var sensor in snap.Overheating)
            {
                desired[OverheatId(serial, sensor)] = new Desired(
                    new AlertSource.Overheat(sensor), new RuleOutcome(true, snap.Temperatures[(int)sensor]), 0, false);
            }
        }

        foreach (var (id, d) in desired.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            Apply(id, serial, d, now);
        }

        foreach (var (id, a) in _instances.ToList())
        {
            if (a.Serial != serial || desired.ContainsKey(id))
            {
                continue;
            }
            if (unknown.Contains(id))
            {
                // Unknown condition: keep the alert, but a snooze that ran out ends in a firing alert.
                if (a.State == AlertState.Snoozed && a.SnoozedUntil is { } until && now >= until)
                {
                    Refire(id, now);
                }
            }
            else
            {
                Transition(id, AlertState.Idle, now);
            }
        }
        foreach (var id in _pending.Keys.ToList())
        {
            if (!desired.ContainsKey(id))
            {
                _pending.Remove(id);
            }
        }
    }

    private void Apply(string id, ProbeSerial serial, Desired d, DateTimeOffset now)
    {
        if (d.Outcome.Met)
        {
            if (_instances.TryGetValue(id, out var t))
            {
                t = t with { Value = d.Outcome.Value ?? t.Value };
                _instances[id] = t;
                if (t.State == AlertState.Snoozed && t.SnoozedUntil is { } until && now >= until)
                {
                    Refire(id, now);
                }
                return;
            }
            var p = _pending.TryGetValue(id, out var known) ? known : new Pending(d.Outcome.Since ?? now, d.Sustain);
            p = p with { Sustain = d.Sustain };
            if (d.Outcome.Since is { } since)
            {
                p = p with { Since = since };
            }
            _pending[id] = p;
            if (now.Since(p.Since) < d.Sustain - Epsilon)
            {
                return;
            }
            _pending.Remove(id);
            _instances[id] = new AlertInstance(id, serial, d.Source, AlertState.Idle, now, Value: d.Outcome.Value);
            Transition(id, AlertState.Firing, now);
        }
        else
        {
            _pending.Remove(id);
            if (!_instances.TryGetValue(id, out var t))
            {
                return;
            }
            // A latched alert outlives its condition until someone acknowledges it.
            if (d.Latch && t.State is AlertState.Firing or AlertState.Snoozed)
            {
                if (t.State == AlertState.Snoozed && t.SnoozedUntil is { } until && now >= until)
                {
                    Refire(id, now);
                }
                return;
            }
            Transition(id, AlertState.Idle, now);
        }
    }

    private void Refire(string id, DateTimeOffset now)
    {
        if (_instances.TryGetValue(id, out var t))
        {
            _instances[id] = t with { SnoozedUntil = null };
        }
        Transition(id, AlertState.Firing, now);
    }

    // Transitions

    /// <summary>Applies a state change and queues its event. <c>Idle</c> removes the alert.</summary>
    private void Transition(string id, AlertState to, DateTimeOffset now, string? failure = null)
    {
        if (!_instances.TryGetValue(id, out var t))
        {
            return;
        }
        var from = t.State;
        if (from == to)
        {
            return;
        }
        t = t with { State = to };
        switch (to)
        {
            case AlertState.Firing:
                if (from == AlertState.Idle)
                {
                    t = t with { FiredAt = now };
                }
                t = t with { SnoozedUntil = null };
                break;
            case AlertState.Acknowledged:
                t = t with { AcknowledgedAt = now, SnoozedUntil = null };
                break;
        }
        if (to == AlertState.Idle)
        {
            _instances.Remove(id);
        }
        else
        {
            _instances[id] = t;
        }
        var e = new AlertEvent(t, from, to, now, failure);
        _outbox.Enqueue(new Outgoing.Event(e));
        _events.Send(e);
        _trace?.Emit("alert", new Dictionary<string, TraceValue>
        {
            ["rule"] = id,
            ["serial"] = t.Serial,
            ["transition"] = e.Transition,
            ["value"] = t.Value is { } v ? v : TraceValue.None,
        });
    }

    private void DropProbe(ProbeSerial serial)
    {
        var now = _clock.Now();
        foreach (var (id, a) in _instances.ToList())
        {
            if (a.Serial == serial)
            {
                Transition(id, AlertState.Idle, now);
            }
        }
        foreach (var id in _pending.Keys.Where(k => k.StartsWith(serial.Hex + ".", StringComparison.Ordinal)).ToList())
        {
            _pending.Remove(id);
        }
        _cooks.Remove(serial);
        _history.Remove(serial);
    }

    // Cook activity and keep-awake

    private void UpdateCook(ProbeSerial serial, ProbeSnapshot snap, DateTimeOffset now)
    {
        if (!_cooks.TryGetValue(serial, out var c))
        {
            c = new CookState();
            _cooks[serial] = c;
        }
        if (!snap.IsOffline)
        {
            c.Active = RuleEvaluator.IsCooking(snap);
            if (c.Active)
            {
                c.LastActive = now;
            }
        }
        else if (c.Active && c.LastActive is { } last && now.Since(last) >= _cookIdle - Epsilon)
        {
            c.Active = false;
        }
    }

    /// <summary>After a round of evaluations: publish the active list, update keep-awake, set the next wake-up.</summary>
    private void FinishRound()
    {
        _active.Send(SortedActive());
        ScheduleWake();
        var want = _followed.Any(s => _cooks.GetValueOrDefault(s)?.Active == true);
        if (want != _held)
        {
            _held = want;
            _outbox.Enqueue(new Outgoing.KeepAwake(want));
        }
    }

    private ValueList<AlertInstance> SortedActive()
    {
        var list = _instances.Values.ToList();
        list.Sort((a, b) =>
        {
            if (a.Priority != b.Priority)
            {
                return b.Priority.CompareTo(a.Priority);
            }
            if (a.FiredAt != b.FiredAt)
            {
                return b.FiredAt.CompareTo(a.FiredAt);
            }
            return string.CompareOrdinal(a.Id, b.Id);
        });
        return list;
    }

    // Timing

    /// <summary>One sleeper for the earliest of: a sustain that is about to be met, a snooze that ends, a quiet cook
    /// that stops counting.</summary>
    private void ScheduleWake()
    {
        _wake?.Cancel();
        _wake = null;
        var now = _clock.Now();
        var times = _pending.Values.Select(p => p.Deadline).ToList();
        times.AddRange(_instances.Values.Where(a => a.State == AlertState.Snoozed && a.SnoozedUntil is not null).Select(a => a.SnoozedUntil!.Value));
        foreach (var (serial, c) in _cooks)
        {
            if (c.Active && _snapshots.GetValueOrDefault(serial)?.IsOffline == true && c.LastActive is { } last)
            {
                times.Add(last.AddSecondsExact(_cookIdle));
            }
        }
        var future = times.Where(t => t > now).ToList();
        if (future.Count == 0)
        {
            return;
        }
        var delay = Math.Max(future.Min().Since(now), 0.001);
        var cts = new CancellationTokenSource();
        _wake = cts;
        _ = WakeAfter(TimeSpan.FromSeconds(delay), cts.Token);
    }

    private async Task WakeAfter(TimeSpan delay, CancellationToken ct)
    {
        try
        {
            await _clock.SleepAsync(delay, ct);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        await WakeUpAsync();
    }

    private async Task WakeUpAsync()
    {
        foreach (var serial in _followed.Order().ToList())
        {
            Evaluate(serial);
        }
        FinishRound();
        await DrainOutboxAsync();
    }

    // Delivery

    /// <summary>Delivers queued events to the sinks in order. One drain at a time keeps the order when calls overlap.</summary>
    private async Task DrainOutboxAsync()
    {
        if (_draining)
        {
            return;
        }
        _draining = true;
        try
        {
            while (_outbox.TryDequeue(out var item))
            {
                switch (item)
                {
                    case Outgoing.Event e:
                        foreach (var sink in _sinks)
                        {
                            await sink.DeliverAsync(e.Value);
                        }
                        break;
                    case Outgoing.KeepAwake k:
                        if (_keepAwake is not null)
                        {
                            await _keepAwake.SetHeldAsync(k.On);
                        }
                        break;
                }
            }
        }
        finally
        {
            _draining = false;
        }
    }

    // Ids

    internal static string AlarmId(ProbeSerial serial, AlarmKind kind, AlarmChannel channel) =>
        $"{serial.Hex}.alarm.{(kind == AlarmKind.High ? "high" : "low")}.{ChannelName(channel)}";

    internal static string OverheatId(ProbeSerial serial, SensorIndex sensor) => $"{serial.Hex}.overheat.t{(int)sensor + 1}";

    /// <summary>Lower-camel channel name (<c>t1</c>, <c>core</c>), as Swift's string interpolation prints it.</summary>
    internal static string ChannelName(AlarmChannel channel)
    {
        var s = channel.ToString();
        return char.ToLowerInvariant(s[0]) + s[1..];
    }
}
