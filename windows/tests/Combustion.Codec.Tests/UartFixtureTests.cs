using System.Text.Json.Nodes;

namespace Combustion.Codec.Tests;

/// <summary>Fixtures in uart_frames/: request encoding, response decoding, and framer streams.</summary>
public class UartFixtureTests
{
    public static IEnumerable<object[]> EncodeRequests() => Fixtures.Rows("uart_frames", "encodeRequest");
    public static IEnumerable<object[]> DecodeResponses() => Fixtures.Rows("uart_frames", "decodeResponse");
    public static IEnumerable<object[]> Streams() => Fixtures.Rows("uart_frames", "stream");

    [Fact]
    public void EveryUartFixtureHasAKnownKind()
    {
        var known = new[] { "encodeRequest", "decodeResponse", "stream" };
        foreach (var file in Fixtures.FileNames("uart_frames"))
        {
            var fixture = Fixtures.Load("uart_frames", file);
            Assert.Contains(fixture.Kind ?? "", known);
        }
    }

    [Theory, MemberData(nameof(EncodeRequests))]
    public void EncodeRequest(string id)
    {
        var fixture = Fixtures.Load(id);
        var variant = Variant(fixture);
        var request = Request(fixture.Root["request"]!);
        var probe = ProbeSerial.FromHex(fixture.Str("probe"));
        var requestId = Uint(fixture.Root["requestId"]);

        if (fixture.ExpectedError is not null)
        {
            var ex = Assert.Throws<CodecException>(() => CombustionCodec.EncodeRequest(variant, request, probe, requestId));
            Assert.Null(Json.FirstDifference(fixture.ExpectedError, Render.Error(ex.Error), subset: true));
            return;
        }

        var bytes = CombustionCodec.EncodeRequest(variant, request, probe, requestId);
        Assert.Equal(fixture.Str("expectedHex"), Hex.String(bytes));

        // And back: framer + DecodeRequest recover the request.
        var framer = new UartFramer(variant, UartDirection.Request);
        var outputs = framer.Push(bytes);
        var frame = Assert.IsType<UartFramerOutput.FrameOutput>(Assert.Single(outputs)).Frame;
        var decoded = CombustionCodec.DecodeRequest(frame);
        Assert.True(SameRequest(decoded.Request, Normalized(request)), fixture.Description);
        Assert.Equal(variant == UartVariant.Node ? probe : null, decoded.Probe);
        Assert.Equal(variant == UartVariant.Node ? requestId : null, decoded.RequestId);
    }

    [Theory, MemberData(nameof(DecodeResponses))]
    public void DecodeResponse(string id)
    {
        var fixture = Fixtures.Load(id);
        var variant = Variant(fixture);
        var framer = new UartFramer(variant, UartDirection.Response);
        var frame = Assert.IsType<UartFramerOutput.FrameOutput>(Assert.Single(framer.Push(fixture.Hex))).Frame;
        try
        {
            var response = CombustionCodec.DecodeResponse(frame);
            Assert.True(fixture.ExpectedError is null, $"{fixture.Description}: expected an error");
            var difference = Json.FirstDifference(fixture.Expected, Render.Response(response));
            Assert.True(difference is null, $"{fixture.Description}: {difference}");

            // Encoding the decoded response and decoding that again gives the same response.
            var again = new UartFramer(variant, UartDirection.Response);
            var reframe = Assert.IsType<UartFramerOutput.FrameOutput>(Assert.Single(again.Push(CombustionCodec.EncodeResponse(response, variant)))).Frame;
            Assert.Equal(response, CombustionCodec.DecodeResponse(reframe));
        }
        catch (CodecException error)
        {
            Assert.True(fixture.ExpectedError is not null, $"{fixture.Description}: unexpected {error.Error}");
            var difference = Json.FirstDifference(fixture.ExpectedError, Render.Error(error.Error), subset: true);
            Assert.True(difference is null, $"{fixture.Description}: {difference}");
        }
    }

    [Theory, MemberData(nameof(Streams))]
    public void FramerStream(string id)
    {
        var fixture = Fixtures.Load(id);
        var variant = Variant(fixture);
        var direction = fixture.Str("direction") == "request" ? UartDirection.Request : UartDirection.Response;
        var chunks = fixture.Root["chunks"]!.AsArray().Select(c => Hex.Bytes(c!.GetValue<string>())).ToList();

        var framer = new UartFramer(variant, direction);
        var frames = new JsonArray();
        var errors = new JsonArray();
        var emitted = new List<UartFrame>();
        foreach (var chunk in chunks)
        {
            foreach (var output in framer.Push(chunk))
            {
                switch (output)
                {
                    case UartFramerOutput.FrameOutput f:
                        frames.Add(Render.Frame(f.Frame));
                        emitted.Add(f.Frame);
                        break;
                    case UartFramerOutput.ErrorOutput e:
                        errors.Add(Render.Error(e.Error)!["kind"]!.DeepClone());
                        break;
                }
            }
        }
        var frameDiff = Json.FirstDifference(fixture.Root["expectedFrames"], frames);
        Assert.True(frameDiff is null, $"{fixture.Description} frames: {frameDiff}");
        var errorDiff = Json.FirstDifference(fixture.Root["expectedErrors"], errors);
        Assert.True(errorDiff is null, $"{fixture.Description} errors: got {errors.ToJsonString()}");

        // Every emitted frame re-encodes to bytes the framer accepts again.
        foreach (var frame in emitted)
        {
            var again = new UartFramer(variant, direction);
            var output = Assert.Single(again.Push(frame.Encoded()));
            Assert.Equal(new UartFramerOutput.FrameOutput(frame), output);
        }
    }

    // JSON -> domain

    private static uint? Uint(JsonNode? node) => node is null ? null : (uint)node.GetValue<double>();

    private static UartVariant Variant(Fixture fixture) => fixture.Str("variant") switch
    {
        "probe" => UartVariant.Probe,
        "node" => UartVariant.Node,
        _ => throw new InvalidDataException($"{fixture.Description}: bad variant"),
    };

    internal static UartRequest Request(JsonNode json)
    {
        switch (json["type"]!.GetValue<string>())
        {
            case "readSessionInfo": return new UartRequest.ReadSessionInfo();
            case "readLogs": return new UartRequest.ReadLogs(Uint(json["start"])!.Value, Uint(json["end"])!.Value);
            case "setPrediction":
            {
                var mode = json["mode"]!.GetValue<string>() switch
                {
                    "none" => PredictionMode.None,
                    "timeToRemoval" => PredictionMode.TimeToRemoval,
                    "removalAndResting" => PredictionMode.RemovalAndResting,
                    "reserved" => PredictionMode.Reserved,
                    var other => throw new InvalidDataException("bad prediction mode " + other),
                };
                return new UartRequest.SetPrediction(json["setpoint"]!.GetValue<double>(), mode);
            }
            case "setAlarms": return new UartRequest.SetAlarms(AlarmConfigFrom(json));
            case "silenceAlarms": return new UartRequest.SilenceAlarms();
            case "readProbeFirmware": return new UartRequest.ReadProbeFirmware();
            case "readProbeHardware": return new UartRequest.ReadProbeHardware();
            case "readProbeModel": return new UartRequest.ReadProbeModel();
            default: throw new InvalidDataException("unknown request type " + json.ToJsonString());
        }
    }

    internal static AlarmConfig AlarmConfigFrom(JsonNode json)
    {
        Dictionary<AlarmChannel, Alarm> Side(string key)
        {
            var map = new Dictionary<AlarmChannel, Alarm>();
            if (json[key] is JsonObject obj)
            {
                foreach (var (name, value) in obj)
                {
                    var channel = Enum.GetValues<AlarmChannel>().First(c => AlarmConfig.ChannelName(c) == name);
                    map[channel] = new Alarm(
                        value!["set"]?.GetValue<bool>() ?? false,
                        value["temperature"]!.GetValue<double>(),
                        value["tripped"]?.GetValue<bool>() ?? false,
                        value["alarming"]?.GetValue<bool>() ?? false);
                }
            }
            return map;
        }
        return new AlarmConfig(Side("high"), Side("low"));
    }

    /// <summary>Equality with a tolerance on alarm temperatures (0.1 steps are not exact in binary floating point).</summary>
    internal static bool SameRequest(UartRequest a, UartRequest b)
    {
        if (a is UartRequest.SetAlarms x && b is UartRequest.SetAlarms y)
        {
            return Json.FirstDifference(Render.Alarms(y.Config), Render.Alarms(x.Config)) is null;
        }
        return a.Equals(b);
    }

    /// <summary>What decoding should return for a request: missing alarm channels come back as <c>Alarm.Unset</c>.</summary>
    internal static UartRequest Normalized(UartRequest request)
    {
        if (request is not UartRequest.SetAlarms set)
        {
            return request;
        }
        IReadOnlyDictionary<AlarmChannel, Alarm> Fill(IReadOnlyDictionary<AlarmChannel, Alarm> d) =>
            Enum.GetValues<AlarmChannel>().ToDictionary(c => c, c => d.TryGetValue(c, out var a) ? a : Alarm.Unset);
        return new UartRequest.SetAlarms(new AlarmConfig(Fill(set.Config.High), Fill(set.Config.Low)));
    }
}
