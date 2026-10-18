using Combustion.Core;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace Combustion.Windows.Platform;

/// <summary>Loops built-in Windows sounds with <see cref="MediaPlayer"/> (06 §17.3). Nothing is bundled; sounds are
/// addressed as <c>ms-winsoundevent:</c> URIs. Untested on Windows (built on Linux only).</summary>
public sealed class MediaSoundPlayer : ISoundPlaying, IDisposable
{
    /// <summary>Built-in Windows sound per alert sound (looping system sounds).</summary>
    public static readonly IReadOnlyDictionary<AlertSound, string> Sounds = new Dictionary<AlertSound, string>
    {
        [AlertSound.Ready] = "ms-winsoundevent:Notification.Looping.Alarm",
        [AlertSound.Overheat] = "ms-winsoundevent:Notification.Looping.Alarm10",
        [AlertSound.ProbeAlarm] = "ms-winsoundevent:Notification.Looping.Alarm2",
        [AlertSound.Alert] = "ms-winsoundevent:Notification.Looping.Alarm4",
    };

    private readonly object _lock = new();
    private readonly Dictionary<string, MediaPlayer> _playing = [];
    private readonly double _volume;

    /// <param name="volume">0...1 (Settings → Alarm volume, default 0.8).</param>
    public MediaSoundPlayer(double volume = 0.8)
    {
        _volume = volume;
    }

    public Task StartLoopAsync(AlertSound sound, string id)
    {
        var uri = new Uri(Sounds.TryGetValue(sound, out var s) ? s : Sounds[AlertSound.Alert]);
        var player = new MediaPlayer
        {
            Source = MediaSource.CreateFromUri(uri),
            IsLoopingEnabled = true,
            Volume = _volume,
            AudioCategory = MediaPlayerAudioCategory.Alerts,
        };
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
            all = [.. _playing.Values];
            _playing.Clear();
        }
        foreach (var p in all)
        {
            p.Dispose();
        }
    }
}
