using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Combustion.Sim;

/// <summary>
/// One line of <c>events.jsonl</c> (docs/05 §4). <c>T</c> is seconds since the start of the recording.
/// <c>Rssi</c> is used by <c>adv</c>; <c>State</c> (a <see cref="BluetoothState"/> raw value such as <c>poweredOff</c>)
/// by <c>state</c> events.
/// </summary>
public sealed record ReplayEvent(
    double T,
    ReplayEvent.Kind Type,
    string? Peripheral = null,
    string? Char = null,
    string? Hex = null,
    int? Rssi = null,
    string? State = null)
{
    /// <summary>Wire names are the lowercase case names (<c>adv</c>, <c>notify</c>, ...).</summary>
    public enum Kind { Adv, Notify, Write, Connect, Disconnect, State }

    /// <summary><see cref="Hex"/> decoded; empty when absent or not hex.</summary>
    public byte[] Bytes => Hex is { } h ? HexString.Decode(h) ?? [] : [];

    internal static string KindName(Kind kind) => kind switch
    {
        Kind.Adv => "adv",
        Kind.Notify => "notify",
        Kind.Write => "write",
        Kind.Connect => "connect",
        Kind.Disconnect => "disconnect",
        Kind.State => "state",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    internal static Kind? ParseKind(string? name) => name switch
    {
        "adv" => Kind.Adv,
        "notify" => Kind.Notify,
        "write" => Kind.Write,
        "connect" => Kind.Connect,
        "disconnect" => Kind.Disconnect,
        "state" => Kind.State,
        _ => null,
    };
}

/// <summary><c>meta.json</c>: device list, firmware versions, OS, adapter, notes.</summary>
public sealed record ReplayMeta
{
    public sealed record Device(string Peripheral, string? Name = null, string? Firmware = null);

    public ReplayMeta(
        int formatVersion = 1, string? name = null, ValueList<Device>? devices = null,
        string? os = null, string? adapter = null, string? notes = null)
    {
        FormatVersion = formatVersion;
        Name = name;
        Devices = devices ?? ValueList<Device>.Empty;
        Os = os;
        Adapter = adapter;
        Notes = notes;
    }

    public int FormatVersion { get; init; }

    public string? Name { get; init; }

    public ValueList<Device> Devices { get; init; }

    public string? Os { get; init; }

    public string? Adapter { get; init; }

    public string? Notes { get; init; }
}

public enum ReplayErrorKind { BadLine, MissingFile }

/// <summary>Swift <c>ReplayError</c>: <c>badLine(number:text:)</c> or <c>missingFile(_:)</c>.</summary>
public sealed class ReplayException : Exception
{
    private ReplayException(ReplayErrorKind kind, string message, int number, string text)
        : base(message)
    {
        Kind = kind;
        Number = number;
        Text = text;
    }

    public ReplayErrorKind Kind { get; }

    /// <summary>1-based line number (<see cref="ReplayErrorKind.BadLine"/>).</summary>
    public int Number { get; }

    /// <summary>The bad line, or the missing file's name.</summary>
    public string Text { get; }

    public static ReplayException BadLine(int number, string text) =>
        new(ReplayErrorKind.BadLine, $"events.jsonl line {number}: {text}", number, text);

    public static ReplayException MissingFile(string name) =>
        new(ReplayErrorKind.MissingFile, $"missing {name}", 0, name);
}

/// <summary>Swift <c>BluetoothState</c> raw values (<c>poweredOn</c>, ...), as replay files spell them.</summary>
public static class BluetoothStateNames
{
    public static string RawValue(this BluetoothState state)
    {
        var s = state.ToString();
        return char.ToLowerInvariant(s[0]) + s[1..];
    }

    public static BluetoothState? Parse(string? raw) =>
        raw is { Length: > 0 } && char.IsLower(raw[0]) &&
        Enum.TryParse<BluetoothState>(char.ToUpperInvariant(raw[0]) + raw[1..], ignoreCase: false, out var s) &&
        Enum.IsDefined(s)
            ? s
            : null;
}

/// <summary>JSON exactly as Swift's <c>JSONEncoder</c> with <c>.sortedKeys, .withoutEscapingSlashes</c> writes it.</summary>
internal static class ReplayJson
{
    private static readonly JsonWriterOptions LineOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Indented = false,
    };

    /// <summary>One <c>events.jsonl</c> line, keys sorted, nulls omitted, no newline.</summary>
    public static byte[] EncodeEvent(ReplayEvent e)
    {
        using var buffer = new MemoryStream();
        using (var w = new Utf8JsonWriter(buffer, LineOptions))
        {
            w.WriteStartObject();
            if (e.Char is { } c)
            {
                w.WriteString("char", c);
            }
            if (e.Hex is { } h)
            {
                w.WriteString("hex", h);
            }
            if (e.Peripheral is { } p)
            {
                w.WriteString("peripheral", p);
            }
            if (e.Rssi is { } r)
            {
                w.WriteNumber("rssi", r);
            }
            if (e.State is { } s)
            {
                w.WriteString("state", s);
            }
            w.WriteNumber("t", e.T);
            w.WriteString("type", ReplayEvent.KindName(e.Type));
            w.WriteEndObject();
        }
        return buffer.ToArray();
    }

    /// <summary>Null when the line is not a valid event.</summary>
    public static ReplayEvent? DecodeEvent(string line)
    {
        try
        {
            using var doc = JsonDocument.Parse(line);
            var o = doc.RootElement;
            if (o.ValueKind != JsonValueKind.Object ||
                !o.TryGetProperty("t", out var t) || t.ValueKind != JsonValueKind.Number ||
                !o.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String ||
                ReplayEvent.ParseKind(type.GetString()) is not { } kind)
            {
                return null;
            }
            int? rssi = null;
            if (o.TryGetProperty("rssi", out var r) && r.ValueKind != JsonValueKind.Null)
            {
                if (r.ValueKind != JsonValueKind.Number || !r.TryGetInt32(out var v))
                {
                    return null;
                }
                rssi = v;
            }
            return new ReplayEvent(
                t.GetDouble(), kind, OptionalString(o, "peripheral"), OptionalString(o, "char"),
                OptionalString(o, "hex"), rssi, OptionalString(o, "state"));
        }
        catch (Exception e) when (e is JsonException or FormatException or InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>Throws <see cref="InvalidOperationException"/> for a present value that is not a string.</summary>
    private static string? OptionalString(JsonElement o, string key)
    {
        if (!o.TryGetProperty(key, out var v) || v.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return v.ValueKind == JsonValueKind.String ? v.GetString() : throw new InvalidOperationException(key);
    }

    /// <summary>Pretty-printed like Darwin's <c>JSONEncoder</c> (<c>.prettyPrinted, .sortedKeys</c>): two-space indent,
    /// <c>"key" : value</c>.</summary>
    public static string EncodeMeta(ReplayMeta meta)
    {
        var fields = new List<(string Key, object Value)>();
        if (meta.Adapter is { } adapter)
        {
            fields.Add(("adapter", adapter));
        }
        fields.Add(("devices", meta.Devices.Select(d =>
        {
            var f = new List<(string, object)>();
            if (d.Firmware is { } fw)
            {
                f.Add(("firmware", fw));
            }
            if (d.Name is { } n)
            {
                f.Add(("name", n));
            }
            f.Add(("peripheral", d.Peripheral));
            return (object)f;
        }).ToList()));
        fields.Add(("formatVersion", meta.FormatVersion));
        if (meta.Name is { } name)
        {
            fields.Add(("name", name));
        }
        if (meta.Notes is { } notes)
        {
            fields.Add(("notes", notes));
        }
        if (meta.Os is { } os)
        {
            fields.Add(("os", os));
        }
        var sb = new StringBuilder();
        WritePretty(sb, fields, 0);
        return sb.ToString();
    }

    private static void WritePretty(StringBuilder sb, object value, int depth)
    {
        var pad = new string(' ', 2 * (depth + 1));
        var close = new string(' ', 2 * depth);
        switch (value)
        {
            case string s:
                sb.Append(Quote(s));
                break;
            case int i:
                sb.Append(i.ToString(CultureInfo.InvariantCulture));
                break;
            case List<(string Key, object Value)> obj:
                sb.Append("{\n");
                for (var k = 0; k < obj.Count; k++)
                {
                    sb.Append(pad).Append(Quote(obj[k].Key)).Append(" : ");
                    WritePretty(sb, obj[k].Value, depth + 1);
                    sb.Append(k < obj.Count - 1 ? ",\n" : "\n");
                }
                if (obj.Count == 0)
                {
                    sb.Append('\n');
                }
                sb.Append(close).Append('}');
                break;
            case List<object> array:
                sb.Append("[\n");
                for (var k = 0; k < array.Count; k++)
                {
                    sb.Append(pad);
                    WritePretty(sb, array[k], depth + 1);
                    sb.Append(k < array.Count - 1 ? ",\n" : "\n");
                }
                if (array.Count == 0)
                {
                    sb.Append('\n');
                }
                sb.Append(close).Append(']');
                break;
            default:
                throw new ArgumentException($"unsupported JSON value {value.GetType()}", nameof(value));
        }
    }

    private static string Quote(string s)
    {
        using var buffer = new MemoryStream();
        using (var w = new Utf8JsonWriter(buffer, LineOptions))
        {
            w.WriteStringValue(s);
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>Same rules as Swift's synthesized <c>Decodable</c>: <c>formatVersion</c> and <c>devices</c> are required.</summary>
    public static ReplayMeta DecodeMeta(string text)
    {
        using var doc = JsonDocument.Parse(text);
        var o = doc.RootElement;
        if (o.ValueKind != JsonValueKind.Object ||
            !o.TryGetProperty("formatVersion", out var version) || version.ValueKind != JsonValueKind.Number ||
            !o.TryGetProperty("devices", out var devices) || devices.ValueKind != JsonValueKind.Array)
        {
            throw new JsonException("meta.json: formatVersion and devices are required");
        }
        try
        {
            var list = new List<ReplayMeta.Device>();
            foreach (var d in devices.EnumerateArray())
            {
                if (d.ValueKind != JsonValueKind.Object || OptionalString(d, "peripheral") is not { } peripheral)
                {
                    throw new JsonException("meta.json: device without peripheral");
                }
                list.Add(new ReplayMeta.Device(peripheral, OptionalString(d, "name"), OptionalString(d, "firmware")));
            }
            return new ReplayMeta(
                version.GetInt32(), OptionalString(o, "name"), list, OptionalString(o, "os"),
                OptionalString(o, "adapter"), OptionalString(o, "notes"));
        }
        catch (Exception e) when (e is FormatException or InvalidOperationException)
        {
            throw new JsonException("meta.json: " + e.Message, e);
        }
    }
}

/// <summary>Writes a replay directory. Thread-safe; <see cref="Append"/> never throws (see <see cref="LastError"/>).</summary>
public sealed class ReplayWriter : IDisposable
{
    private readonly object _lock = new();
    private FileStream? _handle;
    private Exception? _failure;

    public ReplayWriter(string directory, ReplayMeta? meta = null)
    {
        Directory = directory;
        System.IO.Directory.CreateDirectory(directory);
        File.WriteAllBytes(Path.Combine(directory, "meta.json"), Encoding.UTF8.GetBytes(ReplayJson.EncodeMeta(meta ?? new ReplayMeta())));
        _handle = new FileStream(Path.Combine(directory, "events.jsonl"), FileMode.Create, FileAccess.Write, FileShare.Read);
    }

    /// <summary>Rewrites meta.json, e.g. with the devices heard once a capture ends.</summary>
    public void WriteMeta(ReplayMeta meta) =>
        File.WriteAllBytes(Path.Combine(Directory, "meta.json"), Encoding.UTF8.GetBytes(ReplayJson.EncodeMeta(meta)));

    public string Directory { get; }

    public Exception? LastError
    {
        get
        {
            lock (_lock)
            {
                return _failure;
            }
        }
    }

    public void Append(ReplayEvent e)
    {
        var rounded = e with { T = Math.Round(e.T * 1000, MidpointRounding.AwayFromZero) / 1000 };
        lock (_lock)
        {
            if (_handle is null)
            {
                return;
            }
            try
            {
                _handle.Write(ReplayJson.EncodeEvent(rounded));
                _handle.WriteByte(0x0A);
                _handle.Flush();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ObjectDisposedException)
            {
                _failure = ex;
            }
        }
    }

    public void Close()
    {
        lock (_lock)
        {
            try
            {
                _handle?.Dispose();
            }
            catch (IOException)
            {
            }
            _handle = null;
        }
    }

    public void Dispose() => Close();
}

public sealed class ReplayReader
{
    public ReplayReader(string directory)
    {
        var metaPath = Path.Combine(directory, "meta.json");
        var eventsPath = Path.Combine(directory, "events.jsonl");
        if (!File.Exists(eventsPath))
        {
            throw ReplayException.MissingFile("events.jsonl");
        }
        Meta = File.Exists(metaPath) ? ReplayJson.DecodeMeta(File.ReadAllText(metaPath, Encoding.UTF8)) : new ReplayMeta();
        var text = File.ReadAllText(eventsPath, Encoding.UTF8);
        var parsed = new List<ReplayEvent>();
        var lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < lines.Length; i++)
        {
            parsed.Add(ReplayJson.DecodeEvent(lines[i]) ?? throw ReplayException.BadLine(i + 1, lines[i]));
        }
        Events = parsed;
    }

    public ReplayMeta Meta { get; }

    public IReadOnlyList<ReplayEvent> Events { get; }
}
