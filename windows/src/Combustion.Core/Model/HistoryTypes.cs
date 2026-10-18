using Combustion.Codec;

namespace Combustion.Core;

/// <summary>
/// Identifies one cook. docs/02 §2 defines <c>(serial, sessionId)</c>; because <c>sessionId = 0</c> repeats across
/// cooks on old firmware (docs/02 §11), <c>StartedAtMs</c> (ms precision, as stored) completes the key.
/// </summary>
public readonly record struct SessionKey(ProbeSerial Serial, uint SessionId, long StartedAtMs)
{
    public SessionKey(ProbeSerial serial, uint sessionId, DateTimeOffset startedAt)
        : this(serial, sessionId, Time.ToMs(startedAt))
    {
    }

    public DateTimeOffset StartedAt => Time.FromMs(StartedAtMs);
}

/// <summary>Millisecond conversions used by the schema (all <c>*_at</c> columns are Unix ms).</summary>
public static class Time
{
    public static long ToMs(DateTimeOffset t) => (long)Math.Round((t - DateTimeOffset.UnixEpoch).TotalMilliseconds, MidpointRounding.AwayFromZero);

    public static DateTimeOffset FromMs(long ms) => DateTimeOffset.UnixEpoch.AddTicks(ms * TimeSpan.TicksPerMillisecond);

    /// <summary>Seconds as a double, like Swift's <c>timeIntervalSince</c>.</summary>
    public static double Since(this DateTimeOffset a, DateTimeOffset b) => (a - b).TotalSeconds;

    public static DateTimeOffset AddSecondsExact(this DateTimeOffset t, double seconds) =>
        t.AddTicks((long)Math.Round(seconds * TimeSpan.TicksPerSecond));
}

/// <summary>docs/02 §6.3: predictive if a setpoint was set at any point.</summary>
public enum SessionKind { Predictive, Manual }

/// <summary><c>time(seq) = anchorTime − (anchorSeq − seq) × samplePeriod</c> (docs/02 §6.3).</summary>
public static class TimeDerivation
{
    public static DateTimeOffset TimeOf(uint seq, uint anchorSeq, DateTimeOffset anchorTime, double samplePeriod) =>
        anchorTime.AddSecondsExact(-((double)anchorSeq - seq) * samplePeriod);

    /// <summary>Inverse, fractional: where <paramref name="time"/> falls on the seq axis.</summary>
    public static double SeqAt(DateTimeOffset time, uint anchorSeq, DateTimeOffset anchorTime, double samplePeriod) =>
        anchorSeq - anchorTime.Since(time) / samplePeriod;
}

/// <summary>One log record with its derived time. docs/02 §3.</summary>
/// <param name="Temperatures">T1...T8 in °C.</param>
public sealed record TemperatureSample(uint Seq, DateTimeOffset Time, ValueList<double> Temperatures, VirtualSensors VirtualSensors, PredictionLog Prediction)
{
    public double Core => Temperatures[(int)VirtualSensors.Core];
    public double Surface => Temperatures[(int)VirtualSensors.Surface];
    public double Ambient => Temperatures[(int)VirtualSensors.Ambient];
}

public readonly record struct MinMax(double Min, double Max);

/// <summary>One bucket of a downsampled series: min and max of each virtual channel so spikes stay visible.</summary>
public sealed record TemperatureBucket(
    uint FirstSeq, uint LastSeq, DateTimeOffset StartTime, DateTimeOffset EndTime, int SampleCount,
    MinMax Core, MinMax Surface, MinMax Ambient);

/// <summary>All stored samples of one session, times derived from the latest anchor. docs/02 §3, §6.3.</summary>
/// <param name="Samples">Ascending by seq. May have holes (gaps not yet backfilled).</param>
public sealed record TemperatureSeries(SessionKey Key, double SamplePeriod, uint AnchorSeq, DateTimeOffset AnchorTime, ValueList<TemperatureSample> Samples)
{
    /// <summary>At most <paramref name="maxPoints"/> buckets of equal seq width (empty buckets are skipped), each with the
    /// min and max of core, surface and ambient. With <c>Samples.Count &lt;= maxPoints</c> every bucket holds one sample.</summary>
    public List<TemperatureBucket> Downsampled(int maxPoints)
    {
        var output = new List<TemperatureBucket>();
        if (maxPoints <= 0 || Samples.Count == 0)
        {
            return output;
        }
        var first = Samples[0];
        var last = Samples[^1];
        var span = (long)last.Seq - first.Seq + 1;
        var buckets = Math.Min(maxPoints, span);
        var currentIndex = -1L;
        foreach (var s in Samples)
        {
            var idx = ((long)s.Seq - first.Seq) * buckets / span;
            var (c, f, a) = (s.Core, s.Surface, s.Ambient);
            if (idx == currentIndex)
            {
                var b = output[^1];
                output[^1] = b with
                {
                    LastSeq = s.Seq,
                    EndTime = s.Time,
                    SampleCount = b.SampleCount + 1,
                    Core = new MinMax(Math.Min(b.Core.Min, c), Math.Max(b.Core.Max, c)),
                    Surface = new MinMax(Math.Min(b.Surface.Min, f), Math.Max(b.Surface.Max, f)),
                    Ambient = new MinMax(Math.Min(b.Ambient.Min, a), Math.Max(b.Ambient.Max, a)),
                };
            }
            else
            {
                currentIndex = idx;
                output.Add(new TemperatureBucket(s.Seq, s.Seq, s.Time, s.Time, 1, new MinMax(c, c), new MinMax(f, f), new MinMax(a, a)));
            }
        }
        return output;
    }
}

public readonly record struct ThumbnailPoint(double Core, double Surface, double Ambient);

public static class Thumbnail
{
    public const int PointCount = 60;

    /// <summary>60 evenly spaced (by seq) points, linearly interpolated between neighbours. Empty if no samples.</summary>
    public static List<ThumbnailPoint> Make(IReadOnlyList<TemperatureSample> samples)
    {
        var output = new List<ThumbnailPoint>(PointCount);
        if (samples.Count == 0)
        {
            return output;
        }
        double lo = samples[0].Seq, hi = samples[^1].Seq;
        var j = 0;
        for (var i = 0; i < PointCount; i++)
        {
            var target = lo + (hi - lo) * i / (PointCount - 1);
            while (j + 1 < samples.Count && samples[j + 1].Seq <= target)
            {
                j++;
            }
            var a = samples[j];
            if (j + 1 < samples.Count && a.Seq < target)
            {
                var b = samples[j + 1];
                var f = (target - a.Seq) / ((double)b.Seq - a.Seq);
                output.Add(new ThumbnailPoint(
                    a.Core + (b.Core - a.Core) * f,
                    a.Surface + (b.Surface - a.Surface) * f,
                    a.Ambient + (b.Ambient - a.Ambient) * f));
            }
            else
            {
                output.Add(new ThumbnailPoint(a.Core, a.Surface, a.Ambient));
            }
        }
        return output;
    }

    /// <summary>Float32 little-endian, core/surface/ambient per point.</summary>
    public static byte[] Encode(IReadOnlyList<ThumbnailPoint> points)
    {
        var output = new byte[points.Count * 12];
        for (var i = 0; i < points.Count; i++)
        {
            var p = points[i];
            BitConverter.TryWriteBytes(output.AsSpan(i * 12), (float)p.Core);
            BitConverter.TryWriteBytes(output.AsSpan(i * 12 + 4), (float)p.Surface);
            BitConverter.TryWriteBytes(output.AsSpan(i * 12 + 8), (float)p.Ambient);
        }
        if (!BitConverter.IsLittleEndian)
        {
            throw new PlatformNotSupportedException("big-endian");
        }
        return output;
    }

    public static List<ThumbnailPoint> Decode(byte[] bytes)
    {
        var output = new List<ThumbnailPoint>();
        if (bytes.Length % 12 != 0)
        {
            return output;
        }
        for (var o = 0; o < bytes.Length; o += 12)
        {
            output.Add(new ThumbnailPoint(
                BitConverter.ToSingle(bytes, o), BitConverter.ToSingle(bytes, o + 4), BitConverter.ToSingle(bytes, o + 8)));
        }
        return output;
    }
}

/// <summary>One row of the history list. docs/02 §6.3, §18.</summary>
/// <param name="End">Null while the session is still open (live).</param>
/// <param name="Setpoint">Setpoint of the last predictive sample, if any.</param>
/// <param name="Thumbnail">60 points; computed at session end, on the fly for open sessions. Empty without samples.</param>
public sealed record SessionSummary(
    SessionKey Key,
    DateTimeOffset Start,
    DateTimeOffset? End,
    double? PeakCore,
    double? Setpoint,
    SessionKind Kind,
    string? Nickname,
    int SampleCount,
    double SamplePeriod,
    DateTimeOffset? ReadySince,
    ValueList<ThumbnailPoint> Thumbnail);

/// <summary>Scrub readout. docs/02 §6.3 <c>valueAt</c>.</summary>
/// <param name="Seq">Nearest stored seq.</param>
/// <param name="Prediction">Prediction log of the nearest sample.</param>
public sealed record SessionValue(DateTimeOffset Time, uint Seq, double Core, double Surface, double Ambient, PredictionLog Prediction)
{
    public PredictionState PredictionState => Prediction.State;
}
