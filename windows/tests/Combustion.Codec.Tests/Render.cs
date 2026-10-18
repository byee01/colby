using System.Text.Json.Nodes;

namespace Combustion.Codec.Tests;

/// <summary>Turns decoded values into the fixture JSON shape (see spec/fixtures/README.md).</summary>
internal static class Render
{
    public static JsonNode? Num<T>(T value) where T : struct, IConvertible =>
        JsonValue.Create(Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture));

    private static JsonNode? Nullable<T>(T? value, Func<T, JsonNode?> f) where T : struct => value is { } v ? f(v) : null;

    /// <summary>Swift prints enum cases lower camel (<c>instantRead</c>), and so do the fixtures.</summary>
    public static JsonNode? Name(object value)
    {
        var s = value.ToString()!;
        return JsonValue.Create(char.ToLowerInvariant(s[0]) + s[1..]);
    }

    public static JsonNode? Sensors(SensorSet set) => new JsonArray(set.Select(s => Name(s)).ToArray());

    public static JsonNode? Virtual(VirtualSensors v) =>
        new JsonObject { ["core"] = Name(v.Core), ["surface"] = Name(v.Surface), ["ambient"] = Name(v.Ambient) };

    public static JsonNode? Preferences(ThermometerPreferences p) =>
        new JsonObject { ["powerMode"] = Name(p.PowerMode), ["highRadioPower"] = p.HighRadioPower };

    public static JsonNode? Temperatures(ProbeTemperatures t) => new JsonArray(t.Celsius.Select(c => Num(c)).ToArray());

    public static JsonNode? Prediction(PredictionStatus p) => new JsonObject
    {
        ["state"] = Name(p.State), ["mode"] = Name(p.Mode), ["type"] = Name(p.Type), ["setpoint"] = Num(p.Setpoint),
        ["heatStart"] = Num(p.HeatStart), ["rawSecondsRemaining"] = Num(p.RawSecondsRemaining), ["estimatedCore"] = Num(p.EstimatedCore),
    };

    public static JsonNode? PredictionLogJson(PredictionLog p) => new JsonObject
    {
        ["virtualSensors"] = Virtual(p.VirtualSensors), ["state"] = Name(p.State), ["mode"] = Name(p.Mode), ["type"] = Name(p.Type),
        ["setpoint"] = Num(p.Setpoint), ["rawSecondsRemaining"] = Num(p.RawSecondsRemaining), ["estimatedCore"] = Num(p.EstimatedCore),
    };

    public static JsonNode? FoodSafeJson(FoodSafe f) => new JsonObject
    {
        ["mode"] = Name(f.Mode), ["product"] = Num(f.Product), ["serving"] = Name(f.Serving),
        ["thresholdTemp"] = Nullable(f.ThresholdTemp, v => Num(v)), ["zValue"] = Nullable(f.ZValue, v => Num(v)),
        ["referenceTemp"] = Nullable(f.ReferenceTemp, v => Num(v)), ["dValue"] = Nullable(f.DValue, v => Num(v)),
        ["targetLogReduction"] = Num(f.TargetLogReduction), ["state"] = Name(f.State), ["logReduction"] = Num(f.LogReduction),
        ["secondsAboveThreshold"] = Num(f.SecondsAboveThreshold), ["logSequence"] = Num(f.LogSequence),
    };

    public static JsonNode? AlarmJson(Alarm a) => new JsonObject
    {
        ["set"] = a.IsSet, ["tripped"] = a.Tripped, ["alarming"] = a.Alarming, ["temperature"] = Num(a.Temperature),
    };

    public static JsonNode? Alarms(AlarmConfig c)
    {
        static JsonObject Side(IReadOnlyDictionary<AlarmChannel, Alarm> d)
        {
            var o = new JsonObject();
            foreach (var (channel, alarm) in d)
            {
                o[AlarmConfig.ChannelName(channel)] = AlarmJson(alarm);
            }
            return o;
        }
        return new JsonObject { ["high"] = Side(c.High), ["low"] = Side(c.Low) };
    }

    public static JsonNode? Status(ProbeStatusPayload s) => new JsonObject
    {
        ["logRange"] = new JsonObject { ["min"] = Num(s.LogRange.Min), ["max"] = Num(s.LogRange.Max) },
        ["temperatures"] = Temperatures(s.Temperatures), ["mode"] = Name(s.Mode), ["color"] = Name(s.Color),
        ["probeNumber"] = Num(s.ProbeNumber), ["batteryLow"] = s.BatteryLow, ["virtualSensors"] = Virtual(s.VirtualSensors),
        ["prediction"] = Prediction(s.Prediction), ["foodSafe"] = Nullable(s.FoodSafe, FoodSafeJson),
        ["overheating"] = Nullable(s.Overheating, Sensors), ["preferences"] = Nullable(s.Preferences, Preferences),
        ["alarms"] = Nullable(s.Alarms, Alarms),
        ["session"] = Nullable(s.Session, v => new JsonObject { ["sessionId"] = Num(v.SessionId), ["samplePeriodMs"] = Num(v.SamplePeriodMs) }),
    };

    public static JsonNode? NodeStatus(NodeProbeStatus n) =>
        new JsonObject { ["probeSerial"] = n.Serial.Hex, ["hopCount"] = Num(n.HopCount), ["status"] = Status(n.Status) };

    private static JsonObject ProbeAdvertisementJson(ProbeAdvertisement p, string kind, int? hopCount = null)
    {
        var o = new JsonObject
        {
            ["kind"] = kind, ["serial"] = p.Serial.Hex, ["temperatures"] = Temperatures(p.Temperatures), ["mode"] = Name(p.Mode),
            ["color"] = Name(p.Color), ["probeNumber"] = Num(p.ProbeNumber), ["batteryLow"] = p.BatteryLow,
            ["virtualSensors"] = Virtual(p.VirtualSensors), ["overheating"] = Nullable(p.Overheating, Sensors),
            ["preferences"] = Nullable(p.Preferences, Preferences),
        };
        if (hopCount is { } hops)
        {
            o["hopCount"] = Num(hops);
        }
        return o;
    }

    public static JsonNode? Advertisement(AdvertisementPacket p) => p switch
    {
        AdvertisementPacket.Probe a => ProbeAdvertisementJson(a.Advertisement, "probe"),
        AdvertisementPacket.Repeated r => ProbeAdvertisementJson(r.Advertisement, "repeated", r.HopCount),
        AdvertisementPacket.Node n => new JsonObject
        {
            ["kind"] = "node", ["productType"] = Num((byte)n.Advertisement.ProductType), ["nodeProductType"] = Name(n.Advertisement.ProductType),
            ["serial"] = n.Advertisement.Serial, ["preferences"] = Nullable(n.Advertisement.Preferences, v => Num(v)),
        },
        AdvertisementPacket.Unknown u => new JsonObject { ["kind"] = "unknown", ["productType"] = Num(u.ProductType) },
        _ => throw new ArgumentException("unknown packet"),
    };

    public static JsonNode? Error(CodecError e) => e switch
    {
        CodecError.TooShort t => new JsonObject { ["kind"] = "tooShort", ["expected"] = Num(t.Expected), ["actual"] = Num(t.Actual) },
        CodecError.BadSync => new JsonObject { ["kind"] = "badSync" },
        CodecError.BadCrc c => new JsonObject { ["kind"] = "badCrc", ["expected"] = Num(c.Expected), ["actual"] = Num(c.Actual) },
        CodecError.UnknownMessageType u => new JsonObject { ["kind"] = "unknownMessageType", ["type"] = Num(u.Type) },
        CodecError.OutOfRange o => new JsonObject { ["kind"] = "outOfRange", ["field"] = o.Field, ["value"] = Num(double.IsNaN(o.Value) ? 0 : o.Value) },
        CodecError.MissingField m => new JsonObject { ["kind"] = "missingField", ["field"] = m.Field },
        _ => throw new ArgumentException("unknown error"),
    };

    public static JsonNode? Frame(UartFrame f) => new JsonObject
    {
        ["direction"] = Name(f.Direction), ["messageType"] = Num(f.MessageType), ["requestId"] = Nullable(f.RequestId, v => Num(v)),
        ["responseId"] = Nullable(f.ResponseId, v => Num(v)), ["success"] = f.Success is { } s ? s : null,
        ["payloadHex"] = Hex.String(f.Payload),
    };

    public static JsonNode? Response(UartResponse r)
    {
        JsonNode? Probe(ProbeSerial? p) => p is { } s ? s.Hex : null;
        JsonNode body = r.Body switch
        {
            ResponseBody.Ack => new JsonObject { ["type"] = "ack" },
            ResponseBody.SessionInfoBody s => new JsonObject
            {
                ["type"] = "sessionInfo", ["probe"] = Probe(s.Probe), ["sessionId"] = Num(s.Info.SessionId), ["samplePeriodMs"] = Num(s.Info.SamplePeriodMs),
            },
            ResponseBody.LogRecordBody l => new JsonObject
            {
                ["type"] = "logRecord", ["probe"] = Probe(l.Probe), ["sequence"] = Num(l.Record.Sequence),
                ["temperatures"] = Temperatures(l.Record.Temperatures), ["prediction"] = PredictionLogJson(l.Record.Prediction),
            },
            ResponseBody.RevisionBody v => new JsonObject
            {
                ["type"] = "revision", ["probe"] = Probe(v.Probe), ["kind"] = Name(v.Kind), ["text"] = v.Text,
            },
            _ => throw new ArgumentException("unknown body"),
        };
        return new JsonObject
        {
            ["messageType"] = Num(r.MessageType), ["success"] = r.Success, ["requestId"] = Nullable(r.RequestId, v => Num(v)),
            ["responseId"] = Nullable(r.ResponseId, v => Num(v)), ["body"] = body,
        };
    }
}
