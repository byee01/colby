using Combustion.Codec;

namespace Combustion.Core;

/// <summary>Where alert events go: notifications, sound, the UI. docs/02 §9. Events arrive in order, one at a time.</summary>
public interface IAlertSink
{
    Task DeliverAsync(AlertEvent e);
}

/// <summary>Keeps the computer from sleeping while a cook is active (docs/02 §9). The engine calls it only when the
/// answer changes. macOS: <c>IOPMAssertion</c> + <c>ProcessInfo.beginActivity</c>; Windows: <c>PowerSetRequest</c>.</summary>
public interface IKeepAwake
{
    Task SetHeldAsync(bool held);
}

// Platform abstractions behind the stock sinks

/// <summary>Posts and withdraws OS notifications. macOS: <c>UNUserNotificationCenter</c> (<c>.timeSensitive</c>); Windows: alarm toast.</summary>
public interface INotificationPresenting
{
    Task PostAsync(AlertInstance alert);

    Task WithdrawAsync(string id);
}

/// <summary>Plays a sound in a loop until stopped. macOS: <c>AVAudioPlayer</c>; Windows: <c>MediaPlayer</c>.</summary>
/// <summary>Plays alert sounds, once or in a loop until stopped. macOS: <c>NSSound</c>; Windows: <c>MediaPlayer</c>.</summary>
public interface ISoundPlaying
{
    Task PlayAsync(AlertSound sound);

    Task StartLoopAsync(AlertSound sound, string id);

    Task StopLoopAsync(string id);
}

/// <summary>Notification sink: posts when an alert starts firing (again), withdraws it when it is snoozed or clears.
/// Acknowledging withdraws too, except for overheat: the banner stays until the probe is cool again (06 §7).</summary>
public sealed class NotificationAlertSink(INotificationPresenting presenter) : IAlertSink
{
    public async Task DeliverAsync(AlertEvent e)
    {
        switch (e.To)
        {
            case AlertState.Firing:
                await presenter.PostAsync(e.Instance);
                break;
            case AlertState.Acknowledged:
                if (e.Instance.Source is AlertSource.Overheat)
                {
                    return;
                }
                await presenter.WithdrawAsync(e.Instance.Id);
                break;
            default:
                await presenter.WithdrawAsync(e.Instance.Id);
                break;
        }
    }
}

/// <summary>Sound sink (06 §17.3): a looping sound plays from the moment the alert fires until it is acknowledged,
/// snoozed or clears; any other sound plays once each time the alert fires.</summary>
public sealed class SoundAlertSink(ISoundPlaying player) : IAlertSink
{
    public async Task DeliverAsync(AlertEvent e)
    {
        var sound = e.Instance.Sound;
        if (e.To == AlertState.Firing)
        {
            if (sound.Loops())
            {
                await player.StartLoopAsync(sound, e.Instance.Id);
            }
            else
            {
                await player.PlayAsync(sound);
            }
        }
        else if (e.From == AlertState.Firing && sound.Loops())
        {
            await player.StopLoopAsync(e.Instance.Id);
        }
    }
}

// Test doubles

/// <summary>Collects every event.</summary>
public sealed class RecordingAlertSink : IAlertSink
{
    private readonly object _lock = new();
    private readonly List<AlertEvent> _stored = [];

    public IReadOnlyList<AlertEvent> Events
    {
        get
        {
            lock (_lock)
            {
                return [.. _stored];
            }
        }
    }

    /// <summary><c>"&lt;id&gt; idle-&gt;firing"</c> per event, for compact assertions.</summary>
    public IReadOnlyList<string> Transitions => Events.Select(e => $"{e.Instance.Id} {e.Transition}").ToList();

    public Task DeliverAsync(AlertEvent e)
    {
        lock (_lock)
        {
            _stored.Add(e);
        }
        return Task.CompletedTask;
    }
}

/// <summary>A sound player that remembers which loops are running.</summary>
public sealed class FakeSoundPlayer : ISoundPlaying
{
    private readonly object _lock = new();
    private readonly Dictionary<string, AlertSound> _running = [];
    private readonly List<string> _log = [];

    /// <summary>Loops playing right now, by alert id.</summary>
    public IReadOnlyDictionary<string, AlertSound> Playing
    {
        get
        {
            lock (_lock)
            {
                return new Dictionary<string, AlertSound>(_running);
            }
        }
    }

    /// <summary><c>"start &lt;id&gt;"</c> / <c>"stop &lt;id&gt;"</c> / <c>"once &lt;sound&gt;"</c>, in order.</summary>
    public IReadOnlyList<string> History
    {
        get
        {
            lock (_lock)
            {
                return [.. _log];
            }
        }
    }

    public Task PlayAsync(AlertSound sound)
    {
        lock (_lock)
        {
            _log.Add($"once {AlertSoundName(sound)}");
        }
        return Task.CompletedTask;
    }

    /// <summary>Swift <c>String(describing:)</c>: lowerCamelCase case names.</summary>
    private static string AlertSoundName(AlertSound s) => char.ToLowerInvariant(s.ToString()[0]) + s.ToString()[1..];

    public Task StartLoopAsync(AlertSound sound, string id)
    {
        lock (_lock)
        {
            _running[id] = sound;
            _log.Add($"start {id}");
        }
        return Task.CompletedTask;
    }

    public Task StopLoopAsync(string id)
    {
        lock (_lock)
        {
            _running.Remove(id);
            _log.Add($"stop {id}");
        }
        return Task.CompletedTask;
    }
}

/// <summary>A notification presenter that remembers what is on screen.</summary>
public sealed class FakeNotificationPresenter : INotificationPresenting
{
    private readonly object _lock = new();
    private readonly Dictionary<string, AlertInstance> _shown = [];
    private readonly List<string> _log = [];

    public IReadOnlyDictionary<string, AlertInstance> Visible
    {
        get
        {
            lock (_lock)
            {
                return new Dictionary<string, AlertInstance>(_shown);
            }
        }
    }

    public IReadOnlyList<string> History
    {
        get
        {
            lock (_lock)
            {
                return [.. _log];
            }
        }
    }

    public Task PostAsync(AlertInstance alert)
    {
        lock (_lock)
        {
            _shown[alert.Id] = alert;
            _log.Add($"post {alert.Id}");
        }
        return Task.CompletedTask;
    }

    public Task WithdrawAsync(string id)
    {
        lock (_lock)
        {
            _shown.Remove(id);
            _log.Add($"withdraw {id}");
        }
        return Task.CompletedTask;
    }
}

/// <summary>Records the assertion: held now, and every change in order.</summary>
public sealed class FakeKeepAwake : IKeepAwake
{
    private readonly object _lock = new();
    private bool _current;
    private readonly List<bool> _changes = [];

    public bool IsHeld
    {
        get
        {
            lock (_lock)
            {
                return _current;
            }
        }
    }

    public IReadOnlyList<bool> History
    {
        get
        {
            lock (_lock)
            {
                return [.. _changes];
            }
        }
    }

    public Task SetHeldAsync(bool held)
    {
        lock (_lock)
        {
            _current = held;
            _changes.Add(held);
        }
        return Task.CompletedTask;
    }
}

/// <summary>A silencer that records calls and can be made to fail.</summary>
public sealed class FakeSilencer : IProbeAlarmSilencing
{
    private readonly object _lock = new();
    private readonly List<ProbeSerial> _calls = [];
    private Exception? _failure;

    public IReadOnlyList<ProbeSerial> Silenced
    {
        get
        {
            lock (_lock)
            {
                return [.. _calls];
            }
        }
    }

    /// <summary>Makes the next call throw <paramref name="error"/>.</summary>
    public void FailNext(Exception? error)
    {
        lock (_lock)
        {
            _failure = error;
        }
    }

    public Task SilenceAlarmsAsync(ProbeSerial serial)
    {
        Exception? error;
        lock (_lock)
        {
            _calls.Add(serial);
            error = _failure;
            _failure = null;
        }
        return error is null ? Task.CompletedTask : Task.FromException(error);
    }
}
