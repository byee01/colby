using System.Text.Json;
using System.Text.Json.Serialization;
using Combustion.Codec;

namespace Combustion.Core;

/// <summary>
/// Alert rules and the alert log in SQLite (docs/02 §11 <c>alert_rule</c>, <c>alert_event</c>).
/// <para>Uses its own connection to the app database, so it never contends with <c>HistoryStore</c>. Rules keep their
/// order (<c>position</c>). A serial in <c>alert_rule_set</c> has been configured, so an empty rule list stays empty
/// instead of being re-seeded with the defaults.</para>
/// Confined to the core context (Swift: actor).
/// </summary>
public sealed class SqliteAlertStore : IAlertRuleStore, IDisposable
{
    private readonly SqliteDatabase _db;

    public SqliteAlertStore(SqliteDatabase database)
    {
        _db = database;
        Schema.Migrate(database);
    }

    /// <summary><c>":memory:"</c> or a file path (normally the same file as <c>HistoryStore</c>).</summary>
    public SqliteAlertStore(string path)
        : this(new SqliteDatabase(path))
    {
    }

    /// <summary>Last database error from a call that cannot throw (the <see cref="IAlertRuleStore"/> methods, <see cref="Record"/>).</summary>
    public Exception? LastError { get; private set; }

    public void Dispose() => _db.Dispose();

    // Rules

    public Task<ValueList<AlertRule>?> LoadRulesAsync(ProbeSerial serial) => Task.FromResult(LoadRules(serial));

    public ValueList<AlertRule>? LoadRules(ProbeSerial serial)
    {
        try
        {
            if (_db.Query("SELECT 1 FROM alert_rule_set WHERE serial=?", (long)serial.Raw).Count == 0)
            {
                return null;
            }
            var rows = _db.Query("SELECT id, kind, params_json, enabled FROM alert_rule WHERE serial=? ORDER BY position", (long)serial.Raw);
            var rules = new List<AlertRule>();
            foreach (var row in rows)
            {
                if (row[0] is not string id || row[1] is not string kind)
                {
                    continue;
                }
                var enabled = row[3] is long e ? e != 0 : true;
                if (AlertRuleCoding.Decode(kind, row[2] as string) is { } k)
                {
                    rules.Add(new AlertRule(id, k, enabled));
                }
            }
            return rules;
        }
        catch (Exception error)
        {
            LastError = error;
            return null;
        }
    }

    public Task SaveRulesAsync(ValueList<AlertRule> rules, ProbeSerial serial)
    {
        SaveRules(rules, serial);
        return Task.CompletedTask;
    }

    public void SaveRules(IReadOnlyList<AlertRule> rules, ProbeSerial serial)
    {
        var s = (long)serial.Raw;
        try
        {
            _db.Transaction(() =>
            {
                _db.Run("DELETE FROM alert_rule WHERE serial=?", s);
                for (var i = 0; i < rules.Count; i++)
                {
                    var r = rules[i];
                    var (kind, parameters) = AlertRuleCoding.Encode(r.Kind);
                    _db.Run(
                        "INSERT OR REPLACE INTO alert_rule(id, serial, kind, params_json, enabled, position) VALUES(?,?,?,?,?,?)",
                        r.Id, s, kind, parameters, r.Enabled ? 1L : 0L, (long)i);
                }
                _db.Run("INSERT OR IGNORE INTO alert_rule_set(serial) VALUES(?)", s);
            });
        }
        catch (Exception error)
        {
            LastError = error;
        }
    }

    // Alert log

    /// <summary>Writes every engine event until the stream ends. docs/06 §11 "alerts during this cook".</summary>
    public async Task ConsumeAsync(IAsyncEnumerable<AlertEvent> events, CancellationToken ct = default)
    {
        try
        {
            await foreach (var e in events.WithCancellation(ct))
            {
                Record(e);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }

    /// <summary>One row per firing: opened on <c>-&gt; firing</c> (unless the same firing is only coming back from a
    /// snooze), acknowledged on <c>-&gt; acknowledged</c>, closed on <c>-&gt; idle</c>.</summary>
    public void Record(AlertEvent e)
    {
        var inst = e.Instance;
        try
        {
            switch (e.To)
            {
                case AlertState.Firing:
                    if (e.From == AlertState.Snoozed && OpenRow(inst.Id) is not null)
                    {
                        return;
                    }
                    _db.Run(
                        "INSERT OR IGNORE INTO alert_event(id, rule_id, serial, fired_at, value) VALUES(?,?,?,?,?)",
                        $"{inst.Id}@{Time.ToMs(inst.FiredAt)}", inst.Id, (long)inst.Serial.Raw, Time.ToMs(inst.FiredAt), inst.Value);
                    break;
                case AlertState.Acknowledged:
                    if (OpenRow(inst.Id) is { } acked)
                    {
                        _db.Run("UPDATE alert_event SET acked_at=? WHERE id=?", Time.ToMs(e.At), acked);
                    }
                    break;
                case AlertState.Idle:
                    if (OpenRow(inst.Id) is { } cleared)
                    {
                        _db.Run("UPDATE alert_event SET cleared_at=? WHERE id=?", Time.ToMs(e.At), cleared);
                    }
                    break;
            }
        }
        catch (Exception error)
        {
            LastError = error;
        }
    }

    /// <summary>Logged alerts for a probe that fired in <c>[from, to]</c>, oldest first.</summary>
    public List<AlertLogEntry> Events(ProbeSerial serial, DateTimeOffset from, DateTimeOffset to)
    {
        var rows = _db.Query(
            "SELECT rule_id, fired_at, acked_at, cleared_at, value FROM alert_event WHERE serial=? AND fired_at BETWEEN ? AND ? ORDER BY fired_at",
            (long)serial.Raw, Time.ToMs(from), Time.ToMs(to));
        var output = new List<AlertLogEntry>();
        foreach (var r in rows)
        {
            if (r[0] is not string id || Date(r[1]) is not { } fired)
            {
                continue;
            }
            output.Add(new AlertLogEntry(id, serial, fired, Date(r[2]), Date(r[3]), r[4] is double v ? v : null));
        }
        return output;
    }

    private static DateTimeOffset? Date(object? v) => v is long ms ? Time.FromMs(ms) : null;

    private string? OpenRow(string alertId)
    {
        var rows = _db.Query(
            "SELECT id FROM alert_event WHERE rule_id=? AND cleared_at IS NULL ORDER BY fired_at DESC LIMIT 1", alertId);
        return rows.Count > 0 ? rows[0][0] as string : null;
    }
}

/// <summary>One logged firing of an alert.</summary>
/// <param name="AlertId">The alert instance id: a rule id, <c>&lt;serial&gt;.alarm.&lt;high|low&gt;.&lt;channel&gt;</c> or <c>&lt;serial&gt;.overheat.&lt;sensor&gt;</c>.</param>
public sealed record AlertLogEntry(
    string AlertId,
    ProbeSerial Serial,
    DateTimeOffset FiredAt,
    DateTimeOffset? AcknowledgedAt,
    DateTimeOffset? ClearedAt,
    double? Value);

/// <summary><see cref="AlertRuleKind"/> &lt;-&gt; (<c>kind</c>, <c>params_json</c>) columns. The JSON is the same as
/// Swift's <c>JSONEncoder</c> with <c>.sortedKeys</c>: camelCase keys in ordinal order, absent fields omitted.</summary>
internal static class AlertRuleCoding
{
    internal sealed record Params(
        [property: JsonPropertyName("celsius")] double? Celsius = null,
        [property: JsonPropertyName("channel")] int? Channel = null,
        [property: JsonPropertyName("hysteresis")] double? Hysteresis = null,
        [property: JsonPropertyName("max")] double? Max = null,
        [property: JsonPropertyName("min")] double? Min = null,
        [property: JsonPropertyName("minRise")] double? MinRise = null,
        [property: JsonPropertyName("onlyDuringCook")] bool? OnlyDuringCook = null,
        [property: JsonPropertyName("seconds")] double? Seconds = null,
        [property: JsonPropertyName("sustain")] double? Sustain = null,
        [property: JsonPropertyName("window")] double? Window = null);

    private static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static (string Kind, string? Params) Encode(AlertRuleKind kind)
    {
        var (name, p) = kind switch
        {
            AlertRuleKind.TemperatureAbove k => ("temperatureAbove", new Params(Channel: (int)k.Channel, Celsius: k.Celsius, Hysteresis: k.Hysteresis)),
            AlertRuleKind.TemperatureBelow k => ("temperatureBelow", new Params(Channel: (int)k.Channel, Celsius: k.Celsius, Hysteresis: k.Hysteresis)),
            AlertRuleKind.PredictionWithin k => ("predictionWithin", new Params(Seconds: k.Seconds)),
            AlertRuleKind.PredictionDone => ("predictionDone", null),
            AlertRuleKind.RestingDone => ("restingDone", null),
            AlertRuleKind.AmbientOutOfRange k => ("ambientOutOfRange", new Params(Min: k.Min, Max: k.Max, Sustain: k.Sustain)),
            AlertRuleKind.Stall k => ("stall", new Params(Window: k.Window, MinRise: k.MinRise)),
            AlertRuleKind.ProbeOffline k => ("probeOffline", new Params(Seconds: k.Seconds, OnlyDuringCook: k.OnlyDuringCook)),
            AlertRuleKind.BatteryLow => ("batteryLow", (Params?)null),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
        // Params declares its properties in key order, so the output is sorted like Swift's.
        return (name, p is null ? null : JsonSerializer.Serialize(p, Options));
    }

    public static AlertRuleKind? Decode(string kind, string? parameters)
    {
        var p = new Params();
        if (parameters is not null)
        {
            try
            {
                p = JsonSerializer.Deserialize<Params>(parameters, Options) ?? new Params();
            }
            catch (JsonException)
            {
                // Swift: try? decode ?? Params()
            }
        }
        switch (kind)
        {
            case "temperatureAbove":
            case "temperatureBelow":
                if (p.Channel is not { } raw || !Enum.IsDefined(typeof(AlarmChannel), raw) || p.Celsius is not { } c)
                {
                    return null;
                }
                var ch = (AlarmChannel)raw;
                return kind == "temperatureAbove"
                    ? new AlertRuleKind.TemperatureAbove(ch, c, p.Hysteresis ?? 1)
                    : new AlertRuleKind.TemperatureBelow(ch, c, p.Hysteresis ?? 1);
            case "predictionWithin":
                return p.Seconds is { } s ? new AlertRuleKind.PredictionWithin((int)s) : null;
            case "predictionDone":
                return new AlertRuleKind.PredictionDone();
            case "restingDone":
                return new AlertRuleKind.RestingDone();
            case "ambientOutOfRange":
                if (p.Min is not { } lo || p.Max is not { } hi)
                {
                    return null;
                }
                return new AlertRuleKind.AmbientOutOfRange(lo, hi, p.Sustain ?? 0);
            case "stall":
                return p.MinRise is { } r ? new AlertRuleKind.Stall(p.Window ?? 1800, r) : null;
            case "probeOffline":
                return new AlertRuleKind.ProbeOffline(p.Seconds ?? 60, p.OnlyDuringCook ?? false);
            case "batteryLow":
                return new AlertRuleKind.BatteryLow();
            default:
                return null;
        }
    }
}
