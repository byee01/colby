using Combustion.Core;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace Combustion.Windows.Platform;

/// <summary>Plays built-in Windows sounds with <see cref="MediaPlayer"/> (06 §17.3), once or looped. Nothing is bundled;
/// sounds are addressed as <c>ms-winsoundevent:</c> URIs. Untested on hardware.</summary>
public sealed class MediaSoundPlayer : ISoundPlaying, IDisposable
{
    /// <summary>Built-in Windows sound per alert sound: looping alarms for the sounds that loop, short notification
    /// sounds for the ones that play once (macOS uses Ping, Basso and Submarine for those).</summary>
    public static readonly IReadOnlyDictionary<AlertSound, string> Sounds = new Dictionary<AlertSound, string>
    {
        [AlertSound.Ready] = "ms-winsoundevent:Notification.Looping.Alarm",
        [AlertSound.Overheat] = "ms-winsoundevent:Notification.Looping.Alarm10",
        [AlertSound.ProbeAlarm] = "ms-winsoundevent:Notification.Looping.Alarm2",
        [AlertSound.Countdown] = "ms-winsoundevent:Notification.Reminder",
        [AlertSound.Problem] = "ms-winsoundevent:Notification.Default",
        [AlertSound.Custom] = "ms-winsoundevent:Notification.IM",
    };

    private readonly object _lock = new();
    private readonly Dictionary<string, MediaPlayer> _playing = [];
    /// <summary>One-shot players, held until they end so they are not collected mid-sound.</summary>
    private readonly HashSet<MediaPlayer> _once = [];
    private readonly double _volume;

    /// <param name="volume">0...1 (Settings → Alarm volume, default 0.8).</param>
    public MediaSoundPlayer(double volume = 0.8)
    {
        _volume = volume;
    }

    public Task PlayAsync(AlertSound sound)
    {
        var player = MakePlayer(sound, looping: false);
        player.MediaEnded += (p, _) => Release(p);
        player.MediaFailed += (p, _) => Release(p);
        lock (_lock)
        {
            _once.Add(player);
        }
        player.Play();
        return Task.CompletedTask;
    }

    private void Release(MediaPlayer player)
    {
        lock (_lock)
        {
            _once.Remove(player);
        }
        player.Dispose();
    }

    private MediaPlayer MakePlayer(AlertSound sound, bool looping) => new()
    {
        Source = MediaSource.CreateFromUri(new Uri(Sounds.TryGetValue(sound, out var s) ? s : Sounds[AlertSound.Ready])),
        IsLoopingEnabled = looping,
        Volume = _volume,
        AudioCategory = MediaPlayerAudioCategory.Alerts,
    };

    public Task StartLoopAsync(AlertSound sound, string id)
    {
        var player = MakePlayer(sound, looping: true);
        MediaPlayer? old;
        lock (_lock)
        {
            _playing.Remove(id, out old);
            _playing[id] = player;
        }
        old?.Dispose();
        player.Play();
        return Task.CompletedTask;
    }

    public Task StopLoopAsync(string id)
    {
        MediaPlayer? player;
        lock (_lock)
        {
            _playing.Remove(id, out player);
        }
        if (player is not null)
        {
            player.Pause();
            player.Dispose();
        }
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        List<MediaPlayer> all;
        lock (_lock)
        {
            all = [.. _playing.Values, .. _once];
            _playing.Clear();
            _once.Clear();
        }
        foreach (var p in all)
        {
            p.Dispose();
        }
    }
}
