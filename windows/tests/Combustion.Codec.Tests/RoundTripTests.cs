namespace Combustion.Codec.Tests;

/// <summary>Encode then decode returns the original, for random valid values from many seeds.</summary>
public class RoundTripTests
{
    private const int Iterations = 60;

    public static IEnumerable<object[]> Seeds() => Enumerable.Range(1, 30).Select(s => new object[] { (ulong)s });

    [Theory, MemberData(nameof(Seeds))]
    public void Temperatures(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var t = Gen.Temperatures(rng);
            Assert.Equal(t, ProbeTemperatures.FromPacked(t.Packed()));
            Assert.Equal(t, ProbeTemperatures.FromCelsius(t.Celsius));
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void VirtualSensorBits(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var v = Gen.VirtualSensors(rng);
            Assert.Equal(v, VirtualSensors.FromBits(v.Bits));
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void PredictionStatusAndLog(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var p = Gen.Prediction(rng);
            Assert.Equal(p, PredictionStatus.FromPacked(p.Packed()));
            var l = Gen.PredictionLog(rng);
            Assert.Equal(l, PredictionLog.FromPacked(l.Packed()));
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void Alarms(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var a = Gen.Alarms(rng);
            var bytes = a.Packed();
            Assert.Equal(44, bytes.Length);
            Assert.Equal(a, AlarmConfig.FromPacked(bytes));
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void FoodSafe(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var f = Gen.FoodSafe(rng);
            var packed = f.Packed();
            Assert.Equal(f, Codec.FoodSafe.FromPacked(packed.Data, packed.Status));
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void ProbeStatusBothLayouts(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var status = Gen.Status(rng);
            var current = CombustionCodec.EncodeProbeStatus(status);
            Assert.Equal(100, current.Length);
            Assert.Equal(status, CombustionCodec.DecodeProbeStatus(current));

            var legacy = CombustionCodec.EncodeProbeStatus(status, StatusLayout.Legacy);
            Assert.Equal(94, legacy.Length);
            Assert.Equal(status with { Session = null }, CombustionCodec.DecodeProbeStatus(legacy));
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void NodeStatusBothLayouts(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var node = new NodeProbeStatus(Gen.Serial(rng), Gen.Status(rng), (int)rng.Int(1, 4));
            var current = CombustionCodec.EncodeNodeProbeStatus(node);
            Assert.Equal(105, current.Length);
            Assert.Equal(node, CombustionCodec.DecodeNodeProbeStatus(current));

            var legacy = CombustionCodec.EncodeNodeProbeStatus(node, StatusLayout.Legacy);
            Assert.Equal(99, legacy.Length);
            Assert.Equal(node with { Status = node.Status with { Session = null } }, CombustionCodec.DecodeNodeProbeStatus(legacy));
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void Advertisements(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var probe = new AdvertisementPacket.Probe(Gen.ProbeAdvertisement(rng, withPreferences: true));
            Assert.Equal(probe, CombustionCodec.DecodeAdvertisement(CombustionCodec.EncodeAdvertisement(probe)));

            var hops = (int)rng.Int(1, 4);
            var repeated = new AdvertisementPacket.Repeated(Gen.ProbeAdvertisement(rng, withPreferences: false), hops);
            var bytes = CombustionCodec.EncodeAdvertisement(repeated);
            Assert.Equal(24, bytes.Length);
            Assert.Equal(repeated, CombustionCodec.DecodeAdvertisement(bytes));

            var withPrefs = new AdvertisementPacket.Repeated(Gen.ProbeAdvertisement(rng, withPreferences: true), hops);
            Assert.Equal(withPrefs, CombustionCodec.DecodeAdvertisement(CombustionCodec.EncodeAdvertisement(withPrefs)));

            var type = rng.Pick(new[] { NodeProductType.Display, NodeProductType.Booster });
            var node = new AdvertisementPacket.Node(new NodeAdvertisement(type, Gen.Text(rng, 10).ToUpperInvariant(), rng.Byte(1, 255)));
            Assert.Equal(node, CombustionCodec.DecodeAdvertisement(CombustionCodec.EncodeAdvertisement(node)));
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void Requests(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var node = rng.Bool();
            var request = Gen.Request(rng, node);
            var probe = Gen.Serial(rng);
            var requestId = rng.U32(0, uint.MaxValue);
            var variant = node ? UartVariant.Node : UartVariant.Probe;

            var framer = new UartFramer(variant, UartDirection.Request);
            var bytes = CombustionCodec.EncodeRequest(variant, request, probe, requestId);
            var frame = Assert.IsType<UartFramerOutput.FrameOutput>(framer.Push(bytes).First()).Frame;
            var decoded = CombustionCodec.DecodeRequest(frame);
            Assert.Equal(request, decoded.Request);
            Assert.Equal(node ? probe : null, decoded.Probe);
            Assert.Equal(node ? requestId : null, decoded.RequestId);
            Assert.Equal(request.MessageType, frame.MessageType);
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void Responses(ulong seed)
    {
        var rng = new SeededRng(seed);
        for (var i = 0; i < Iterations; i++)
        {
            var node = rng.Bool();
            var response = Gen.Response(rng, node);
            var variant = node ? UartVariant.Node : UartVariant.Probe;
            var framer = new UartFramer(variant);
            var frame = Assert.IsType<UartFramerOutput.FrameOutput>(framer.Push(CombustionCodec.EncodeResponse(response, variant)).First()).Frame;
            Assert.Equal(response, CombustionCodec.DecodeResponse(frame));
        }
    }

    [Fact]
    public void ProbeSerialHex()
    {
        Assert.Equal("0000002A", new ProbeSerial(0x2A).Hex);
        Assert.Equal(new ProbeSerial(0x2A), ProbeSerial.FromHex("2a"));
        Assert.Equal(uint.MaxValue, ProbeSerial.FromHex("FFFFFFFF")!.Value.Raw);
        Assert.Null(ProbeSerial.FromHex(""));
        Assert.Null(ProbeSerial.FromHex(null));
        Assert.Null(ProbeSerial.FromHex("123456789"));
        Assert.Null(ProbeSerial.FromHex("XYZ"));
        Assert.True(new ProbeSerial(1) < new ProbeSerial(2));
        Assert.True(new ProbeSerial(2) > new ProbeSerial(1));
        Assert.True(new ProbeSerial(2) <= new ProbeSerial(2) && new ProbeSerial(2) >= new ProbeSerial(2));
        Assert.Equal(1, new ProbeSerial(2).CompareTo(new ProbeSerial(1)));
        Assert.Equal("00000ABC", new ProbeSerial(0xABC).ToString());
    }
}
