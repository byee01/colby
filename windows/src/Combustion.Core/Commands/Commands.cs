using Combustion.Codec;

namespace Combustion.Core;

public enum CommandErrorKind
{
    /// <summary>No link can carry the command right now.</summary>
    NotReachable,
    /// <summary>A value outside what the probe accepts (set point 0...102.3 °C, alarm -20...799 °C).</summary>
    OutOfRange,
    /// <summary><c>SetAlarm</c> needs the probe's current alarms (read-modify-write) and no full status has arrived yet.</summary>
    AlarmStateUnknown,
    /// <summary>The probe acknowledged the command but no status showed the new value in time.</summary>
    NotConfirmed,
    Uart,
}

/// <summary>Failures of a probe command. docs/02 §8. Swift <c>CommandError</c>.</summary>
public sealed class CommandException : Exception
{
    public CommandException(CommandErrorKind kind, string? field = null, UartException? uart = null)
        : base(Describe(kind, field, uart), uart)
    {
        Kind = kind;
        Field = field;
        Uart = uart;
    }

    public CommandErrorKind Kind { get; }

    /// <summary>For <c>OutOfRange</c>.</summary>
    public string? Field { get; }

    /// <summary>For <c>Uart</c>.</summary>
    public UartException? Uart { get; }

    public static CommandException NotReachable => new(CommandErrorKind.NotReachable);
    public static CommandException AlarmStateUnknown => new(CommandErrorKind.AlarmStateUnknown);
    public static CommandException NotConfirmed => new(CommandErrorKind.NotConfirmed);
    public static CommandException OutOfRange(string field) => new(CommandErrorKind.OutOfRange, field);

    /// <summary>Trace text, as Swift prints it: <c>notReachable</c>, <c>outOfRange:setpoint</c>, <c>uart:timeout</c>.</summary>
    public string TraceText => Describe(Kind, Field, Uart);

    private static string Describe(CommandErrorKind kind, string? field, UartException? uart) => kind switch
    {
        CommandErrorKind.NotReachable => "notReachable",
        CommandErrorKind.OutOfRange => $"outOfRange:{field}",
        CommandErrorKind.AlarmStateUnknown => "alarmStateUnknown",
        CommandErrorKind.NotConfirmed => "notConfirmed",
        _ => $"uart:{Camel(uart?.Kind.ToString() ?? "")}",
    };

    private static string Camel(string s) => s.Length == 0 ? s : char.ToLowerInvariant(s[0]) + s[1..];
}

/// <summary>One way to deliver a command to a probe: a direct link or a MeatNet node link.</summary>
public interface ICommandRoute
{
    /// <summary>Sends <paramref name="request"/> for <paramref name="probe"/> and returns the response. Throws <see cref="UartException"/>.</summary>
    Task<UartResponse> SendAsync(UartRequest request, ProbeSerial probe, TimeSpan timeout);
}

/// <summary>Picks the route for a probe: direct link if connected, else a node link, else null. docs/02 §8.</summary>
public interface ICommandRouting
{
    ICommandRoute? CommandRoute(ProbeSerial probe);
}

/// <summary>Command route over a direct probe link.</summary>
public sealed class DirectCommandRoute(DirectProbeLink link) : ICommandRoute
{
    public Task<UartResponse> SendAsync(UartRequest request, ProbeSerial probe, TimeSpan timeout) =>
        probe != link.Serial ? throw UartException.Failure : link.Uart.SendAsync(request, timeout: timeout, retries: 1);
}

/// <summary>Command route through a MeatNet node.</summary>
public sealed class NodeCommandRoute(NodeLink link) : ICommandRoute
{
    public Task<UartResponse> SendAsync(UartRequest request, ProbeSerial probe, TimeSpan timeout) =>
        link.SendAsync(request, probe, timeout, retries: 1);
}

/// <summary>
/// Set prediction, set alarms and silence alarms. docs/02 §8.
/// Every command is confirmed by the next status, not by the UART ack alone: after the ack it waits up to
/// <c>confirmTimeout</c> for a status in which the probe shows the new value, and throws <c>NotConfirmed</c> if none comes.
/// The wait runs on the injected clock. Commands for one probe run one at a time (so two <c>SetAlarm</c> calls
/// cannot overwrite each other's read-modify-write); different probes run in parallel.
/// </summary>
public sealed class Commands : IProbeAlarmSilencing
{
    public static readonly TimeSpan DefaultCommandTimeout = TimeSpan.FromSeconds(3);
    public static readonly TimeSpan DefaultConfirmTimeout = TimeSpan.FromSeconds(5);

    /// <summary>Probe resolution is 0.1 °C and the codec rounds to it, but the probe can report one step off what it
    /// was sent: on hardware (fw 2.3.3) a set point sent as 294 (85 °F) came back as 293. One step either way confirms.</summary>
    private const double Tolerance = 0.11;

    private readonly ProbeStore _probes;
    private readonly ICommandRouting _routing;
    private readonly IClock _clock;
    private readonly ITraceSink? _trace;
    private readonly TimeSpan _commandTimeout;
    private readonly TimeSpan _confirmTimeout;
    private readonly Dictionary<ProbeSerial, SemaphoreSlim> _locks = [];

    public Commands(
        ProbeStore probes, ICommandRouting routing, IClock clock, ITraceSink? trace = null,
        TimeSpan? commandTimeout = null, TimeSpan? confirmTimeout = null)
    {
        _probes = probes;
        _routing = routing;
        _clock = clock;
        _trace = trace;
        _commandTimeout = commandTimeout ?? DefaultCommandTimeout;
        _confirmTimeout = confirmTimeout ?? DefaultConfirmTimeout;
    }

    // Prediction

    /// <summary>Starts a prediction. <paramref name="mode"/> must be <c>TimeToRemoval</c> or <c>RemovalAndResting</c>;
    /// use <see cref="CancelPredictionAsync"/> for none.</summary>
    public async Task SetPredictionAsync(ProbeSerial serial, PredictionMode mode, double setpoint)
    {
        if (mode is not (PredictionMode.TimeToRemoval or PredictionMode.RemovalAndResting))
        {
            throw CommandException.OutOfRange("mode");
        }
        ValidateSetpoint(setpoint);
        await RunAsync("setPrediction", serial, new UartRequest.SetPrediction(setpoint, mode),
            s => s.Prediction.Mode == mode && Math.Abs(s.Prediction.Setpoint - setpoint) < Tolerance);
    }

    /// <summary>Ends the prediction (mode none).</summary>
    public Task CancelPredictionAsync(ProbeSerial serial) =>
        RunAsync("cancelPrediction", serial, new UartRequest.SetPrediction(0, PredictionMode.None), s => s.Prediction.Mode == PredictionMode.None);

    // Alarms

    /// <summary>Sets or clears one alarm (<paramref name="temperature"/> null clears it), leaving the other 21 as the probe has them.</summary>
    public async Task SetAlarmAsync(ProbeSerial serial, AlarmChannel channel, AlarmKind kind, double? temperature)
    {
        if (temperature is { } t)
        {
            ValidateAlarm(t, "temperature");
        }
        await ExclusiveAsync(serial, async () =>
        {
            if (_probes.Snapshot(serial)?.Alarms is not { } current)
            {
                throw CommandException.AlarmStateUnknown;
            }
            var config = Clean(current);
            var high = new Dictionary<AlarmChannel, Alarm>(config.High);
            var low = new Dictionary<AlarmChannel, Alarm>(config.Low);
            var alarm = temperature is { } v ? new Alarm(true, v) : Alarm.Unset;
            if (kind == AlarmKind.High)
            {
                high[channel] = alarm;
            }
            else
            {
                low[channel] = alarm;
            }
            var wanted = new AlarmConfig(high, low);
            await SendAsync("setAlarm", serial, new UartRequest.SetAlarms(wanted), s => Matches(s.Alarms, wanted));
        });
    }

    /// <summary>Replaces all 22 alarms. A channel missing from the config is sent as unset.</summary>
    public async Task SetAlarmsAsync(ProbeSerial serial, AlarmConfig config)
    {
        foreach (var (kind, alarms) in new[] { ("high", config.High), ("low", config.Low) })
        {
            foreach (var (channel, alarm) in alarms)
            {
                if (alarm.IsSet)
                {
                    ValidateAlarm(alarm.Temperature, $"{kind}.{char.ToLowerInvariant(channel.ToString()[0])}{channel.ToString()[1..]}");
                }
            }
        }
        var clean = Clean(config);
        await RunAsync("setAlarms", serial, new UartRequest.SetAlarms(clean), s => Matches(s.Alarms, clean));
    }

    /// <summary>Silences every alarming alarm on the probe (and so on its Display and phone). Overheat is not silenced.</summary>
    public Task SilenceAlarmsAsync(ProbeSerial serial) =>
        RunAsync("silenceAlarms", serial, new UartRequest.SilenceAlarms(), s =>
            s.Alarms is { } a && !a.High.Values.Concat(a.Low.Values).Any(x => x.Alarming));

    // Validation and matching

    private static void ValidateSetpoint(double value)
    {
        if (!double.IsFinite(value) || value < 0 || value > CombustionCodec.MaxPredictionSetpoint)
        {
            throw CommandException.OutOfRange("setpoint");
        }
    }

    private static void ValidateAlarm(double value, string field)
    {
        if (!double.IsFinite(value) || value < Alarm.MinTemperature || value > Alarm.MaxTemperature)
        {
            throw CommandException.OutOfRange(field);
        }
    }

    /// <summary>Read-only bits are ignored by the probe on write; send them cleared.</summary>
    private static AlarmConfig Clean(AlarmConfig config)
    {
        static Dictionary<AlarmChannel, Alarm> Strip(IReadOnlyDictionary<AlarmChannel, Alarm> alarms) =>
            alarms.ToDictionary(kv => kv.Key, kv => new Alarm(kv.Value.IsSet, kv.Value.Temperature));
        return new AlarmConfig(Strip(config.High), Strip(config.Low));
    }

    /// <summary>Every alarm of <paramref name="wanted"/> is as the probe reports it (set flag, and temperature when set).</summary>
    private static bool Matches(AlarmConfig? reported, AlarmConfig wanted)
    {
        if (reported is not { } r)
        {
            return false;
        }
        static bool Same(IReadOnlyDictionary<AlarmChannel, Alarm> got, IReadOnlyDictionary<AlarmChannel, Alarm> want) =>
            Enum.GetValues<AlarmChannel>().All(ch =>
            {
                var w = want.TryGetValue(ch, out var x) ? x : Alarm.Unset;
                if (!got.TryGetValue(ch, out var g))
                {
                    return !w.IsSet;
                }
                return g.IsSet == w.IsSet && (!w.IsSet || Math.Abs(g.Temperature - w.Temperature) < Tolerance);
            });
        return Same(r.High, wanted.High) && Same(r.Low, wanted.Low);
    }

    // Sending

    private Task RunAsync(string op, ProbeSerial serial, UartRequest request, Func<ProbeStatusPayload, bool> confirmed) =>
        ExclusiveAsync(serial, () => SendAsync(op, serial, request, confirmed));

    /// <summary>Sends and confirms. Runs inside <see cref="ExclusiveAsync"/>.</summary>
    private async Task SendAsync(string op, ProbeSerial serial, UartRequest request, Func<ProbeStatusPayload, bool> confirmed)
    {
        try
        {
            var route = _routing.CommandRoute(serial) ?? throw CommandException.NotReachable;
            // Subscribe before sending: the confirming status can arrive before the ack does.
            var statuses = _probes.StatusEvents();
            try
            {
                await route.SendAsync(request, serial, _commandTimeout);
            }
            catch (UartException e)
            {
                statuses.Finish();
                throw new CommandException(CommandErrorKind.Uart, uart: e);
            }
            catch
            {
                statuses.Finish();
                throw;
            }
            if (!await WaitForStatusAsync(statuses, serial, confirmed))
            {
                throw CommandException.NotConfirmed;
            }
            _trace?.Emit("command", new Dictionary<string, TraceValue> { ["op"] = op, ["serial"] = serial, ["result"] = "confirmed" });
        }
        catch (CommandException e)
        {
            _trace?.Emit("command", new Dictionary<string, TraceValue> { ["op"] = op, ["serial"] = serial, ["result"] = e.TraceText });
            throw;
        }
    }

    /// <summary>True once a status for <paramref name="serial"/> satisfies <paramref name="confirmed"/>; false after
    /// <c>confirmTimeout</c> on the clock. A stream that ended early does not cut the wait short.</summary>
    private async Task<bool> WaitForStatusAsync(AsyncStream<ProbeStatusEvent> statuses, ProbeSerial serial, Func<ProbeStatusPayload, bool> confirmed)
    {
        using var cts = new CancellationTokenSource();
        var match = MatchAsync(statuses, serial, confirmed, cts.Token);
        var timer = _clock.SleepAsync(_confirmTimeout, cts.Token);
        var first = await Task.WhenAny(match, timer);
        if (first == match && match.Result)
        {
            cts.Cancel();
            return true;
        }
        if (first == match)
        {
            // Stream ended without a match: only the timer decides now.
            await timer;
        }
        cts.Cancel();
        return false;
    }

    private static async Task<bool> MatchAsync(AsyncStream<ProbeStatusEvent> statuses, ProbeSerial serial, Func<ProbeStatusPayload, bool> confirmed, CancellationToken ct)
    {
        try
        {
            await foreach (var e in statuses.WithCancellation(ct))
            {
                if (e.Serial == serial && confirmed(e.Status))
                {
                    return true;
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        return false;
    }

    // One command at a time per probe

    private async Task ExclusiveAsync(ProbeSerial serial, Func<Task> body)
    {
        if (!_locks.TryGetValue(serial, out var gate))
        {
            gate = new SemaphoreSlim(1, 1);
            _locks[serial] = gate;
        }
        await gate.WaitAsync();
        try
        {
            await body();
        }
        finally
        {
            gate.Release();
        }
    }
}
