using System.Globalization;
using System.Text;
using Combustion.Codec;

namespace Combustion.Core;

/// <summary>A value in a parity trace line (docs/05 §3).</summary>
public abstract record TraceValue
{
    private TraceValue() { }

    public sealed record Str(string Value) : TraceValue;
    public sealed record Int(long Value) : TraceValue;
    public sealed record Dbl(double Value) : TraceValue;
    public sealed record Bool(bool Value) : TraceValue;
    public sealed record Null : TraceValue;
    /// <summary>Rendered as an 8-char uppercase hex string.</summary>
    public sealed record Serial(uint Value) : TraceValue;

    public static readonly TraceValue None = new Null();

    public static implicit operator TraceValue(string v) => new Str(v);
    public static implicit operator TraceValue(int v) => new Int(v);
    public static implicit operator TraceValue(long v) => new Int(v);
    public static implicit operator TraceValue(double v) => new Dbl(v);
    public static implicit operator TraceValue(bool v) => new Bool(v);
    public static implicit operator TraceValue(ProbeSerial v) => new Serial(v.Raw);
}

public interface ITraceSink
{
    /// <summary>Records one observable output. The sink adds <c>t</c> and <c>kind</c>.</summary>
    void Emit(string kind, IReadOnlyDictionary<string, TraceValue> fields);
}

/// <summary>
/// One JSON object per line, keys sorted (ordinal), floats rounded to 2 decimals (trailing zeros trimmed),
/// <c>t</c> = clock seconds since the sink was created, rounded to 3 decimals (ms) as in the docs/05 example.
/// </summary>
public sealed class JsonlTraceSink : ITraceSink, IDisposable
{
    private readonly IClock _clock;
    private readonly TimeSpan _origin;
    private readonly object _lock = new();
    private readonly List<string> _lines = [];
    private StreamWriter? _file;

    public JsonlTraceSink(IClock clock, string? filePath = null)
    {
        _clock = clock;
        _origin = clock.Monotonic();
        if (filePath is not null)
        {
            _file = new StreamWriter(filePath, append: false, new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
        }
    }

    public IReadOnlyList<string> Lines
    {
        get
        {
            lock (_lock)
            {
                return [.. _lines];
            }
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _file?.Dispose();
            _file = null;
        }
    }

    public void Emit(string kind, IReadOnlyDictionary<string, TraceValue> fields)
    {
        var all = new Dictionary<string, TraceValue>(fields)
        {
            ["kind"] = kind,
            ["t"] = (_clock.Monotonic() - _origin).TotalSeconds,
        };
        var line = Render(all);
        lock (_lock)
        {
            _lines.Add(line);
            _file?.WriteLine(line);
        }
    }

    internal static string Render(IReadOnlyDictionary<string, TraceValue> fields)
    {
        var parts = fields.Keys.OrderBy(k => k, StringComparer.Ordinal)
            .Select(k => $"{Quote(k)}:{Render(fields[k], k == "t" ? 3 : 2)}");
        return "{" + string.Join(",", parts) + "}";
    }

    internal static string Render(TraceValue v, int decimals) => v switch
    {
        TraceValue.Str s => Quote(s.Value),
        TraceValue.Int i => i.Value.ToString(CultureInfo.InvariantCulture),
        TraceValue.Bool b => b.Value ? "true" : "false",
        TraceValue.Serial s => Quote(s.Value.ToString("X8", CultureInfo.InvariantCulture)),
        TraceValue.Dbl d => Number(d.Value, decimals),
        _ => "null",
    };

    internal static string Number(double d, int decimals)
    {
        if (!double.IsFinite(d))
        {
            return "null";
        }
        // Swift's "%.Nf" rounds half to even on the binary value; "F" in .NET Core 3.0+ formats the exact value too.
        var s = d.ToString("F" + decimals, CultureInfo.InvariantCulture);
        if (s.Contains('.'))
        {
            s = s.TrimEnd('0').TrimEnd('.');
        }
        return s == "-0" ? "0" : s;
    }

    internal static string Quote(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20)
                    {
                        sb.Append(CultureInfo.InvariantCulture, $"\\u{(int)c:X4}");
                    }
                    else
                    {
                        sb.Append(c);
                    }
                    break;
            }
        }
        return sb.Append('"').ToString();
    }
}
