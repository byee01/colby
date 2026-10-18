using System.Text;

namespace Combustion.Codec.Tests;

/// <summary>Validation errors, reserved values and the small helpers: the branches fixtures do not reach.</summary>
public class EdgeCaseTests
{
    private static void Throws(CodecError expected, Action action)
    {
        var ex = Assert.Throws<CodecException>(action);
        Assert.Equal(expected, ex.Error);
    }

    private static void ThrowsAny(Action action) => Assert.Throws<CodecException>(action);

    private static byte[] Zeros(int count) => new byte[count];

    // CRC and bits

    [Fact]
    public void CrcCheckValue()
    {
        Assert.Equal(0x29B1, CombustionCodec.Crc16Ccitt(Encoding.ASCII.GetBytes("123456789")));
        Assert.Equal(0xFFFF, CombustionCodec.Crc16Ccitt([]));
    }

    [Fact]
    public void BitReaderAndWriterAreLsbFirst()
    {
        var writer = new BitWriter(2);
        writer.Write(0b101, 3);
        writer.Write(0x1FF, 9);
        Assert.Equal(new byte[] { 0b1111_1101, 0b0000_1111 }, writer.Bytes);
        var reader = new BitReader(writer.Bytes);
        Assert.Equal(0b101u, reader.Read(3));
        Assert.Equal(0x1FFu, reader.Read(9));
    }

    // Temperatures and sensors

    [Fact]
    public void TemperatureValidation()
    {
        ThrowsAny(() => ProbeTemperatures.FromRaw([0, 1]));
        ThrowsAny(() => ProbeTemperatures.FromRaw(Enumerable.Repeat((ushort)0x2000, 8)));
        ThrowsAny(() => ProbeTemperatures.FromCelsius(Enumerable.Repeat(-20.1, 8)));
        ThrowsAny(() => ProbeTemperatures.FromCelsius(Enumerable.Repeat(390.0, 8)));
        ThrowsAny(() => ProbeTemperatures.FromCelsius(Enumerable.Repeat(double.NaN, 8)));
        var t = ProbeTemperatures.FromCelsius([-20, 369, 22.5, 22.52, 0, 1, 2, 3]);
        Assert.Equal(0, t.Raw[0]);
        Assert.Equal(7780, t.Raw[1]);
        Assert.Equal(850, t.Raw[3]);
        Assert.True(Math.Abs(t[SensorIndex.T2] - 369) < 1e-9);
        Assert.Equal(8, t.Celsius.Count);
        Assert.False(t.Equals(null));
        Assert.True(t.Equals((object)ProbeTemperatures.FromRaw(t.Raw)));
        Assert.Equal(t.GetHashCode(), ProbeTemperatures.FromRaw(t.Raw).GetHashCode());
        Assert.Contains("°C", t.ToString());
    }

    [Fact]
    public void VirtualSensorValidationAndTemperatures()
    {
        ThrowsAny(() => new VirtualSensors(SensorIndex.T7, SensorIndex.T4, SensorIndex.T8));
        ThrowsAny(() => new VirtualSensors(SensorIndex.T1, SensorIndex.T3, SensorIndex.T8));
        ThrowsAny(() => new VirtualSensors(SensorIndex.T1, SensorIndex.T8, SensorIndex.T8));
        ThrowsAny(() => new VirtualSensors(SensorIndex.T1, SensorIndex.T4, SensorIndex.T4));
        var v = new VirtualSensors(SensorIndex.T6, SensorIndex.T7, SensorIndex.T8);
        var t = ProbeTemperatures.FromRaw([100, 200, 300, 400, 500, 600, 700, 800]);
        var picked = v.Temperatures(t);
        Assert.Equal(t[SensorIndex.T6], picked.Core);
        Assert.Equal(t[SensorIndex.T7], picked.Surface);
        Assert.Equal(t[SensorIndex.T8], picked.Ambient);
        // Undefined core values 6 and 7 read as T1.
        Assert.Equal(SensorIndex.T1, VirtualSensors.FromBits(6).Core);
        Assert.Equal(SensorIndex.T1, VirtualSensors.FromBits(7).Core);
    }

    [Fact]
    public void OverheatMaskBitNIsSensorNPlusOne()
    {
        Assert.Equal(SensorSet.Of(SensorIndex.T1, SensorIndex.T3), OverheatMask.Decode(0b0000_0101));
        Assert.Equal(0b1000_0010, OverheatMask.Encode(SensorSet.Of(SensorIndex.T8, SensorIndex.T2)));
        var set = SensorSet.Of(SensorIndex.T5, SensorIndex.T2);
        Assert.Equal(new[] { SensorIndex.T2, SensorIndex.T5 }, set.ToArray());
        Assert.Equal(2, set.Count);
        Assert.True(set.Contains(SensorIndex.T5) && !set.Contains(SensorIndex.T1));
        Assert.Equal("{T2, T5}", set.ToString());
        Assert.Equal(0, SensorSet.Empty.Count);
        Assert.Equal(2, ((System.Collections.IEnumerable)set).Cast<object>().Count());
    }

    // Identifiers

    [Fact]
    public void ModeAndIdByte()
    {
        var ident = ModeAndId.FromByte(0b101_110_01);
        Assert.Equal(ProbeMode.InstantRead, ident.Mode);
        Assert.Equal(ProbeColor.Unknown(6), ident.Color);
        Assert.Equal(6, ident.ProbeNumber);
        Assert.Equal(0b101_110_01, ident.ToByte());
        ThrowsAny(() => new ModeAndId(ProbeMode.Normal, ProbeColor.Yellow, 0).ToByte());
        ThrowsAny(() => new ModeAndId(ProbeMode.Normal, ProbeColor.Yellow, 9).ToByte());
        ThrowsAny(() => new ModeAndId(ProbeMode.Normal, ProbeColor.Unknown(8), 1).ToByte());
        Assert.Equal(ProbeColor.Yellow, new ProbeColor(0));
        Assert.Equal(ProbeColor.Grey, new ProbeColor(1));
        Assert.Equal((byte)5, ProbeColor.Unknown(5).Raw);
        Assert.Equal("Yellow", ProbeColor.Yellow.ToString());
        Assert.Equal("Grey", ProbeColor.Grey.ToString());
        Assert.Equal("Unknown(5)", ProbeColor.Unknown(5).ToString());
    }

    [Fact]
    public void ThermometerPreferencesByte()
    {
        for (byte b = 0; b <= 7; b++)
        {
            Assert.Equal(b, ThermometerPreferences.FromByte(b).ToByte());
        }
        Assert.Equal(0, ThermometerPreferences.FromByte(0xF8).ToByte());
        Assert.Equal(5, new ThermometerPreferences(ProbePowerMode.AlwaysOn, true).ToByte());
        Assert.Equal(2, new ThermometerPreferences(ProbePowerMode.Reserved(2), false).ToByte());
        Assert.Equal("Normal", ProbePowerMode.Normal.ToString());
        Assert.Equal("AlwaysOn", ProbePowerMode.AlwaysOn.ToString());
        Assert.Equal("Reserved(3)", ProbePowerMode.Reserved(3).ToString());
    }

    // Prediction

    [Fact]
    public void PredictionPercentToRemoval()
    {
        var p = new PredictionStatus(PredictionState.Predicting, PredictionMode.TimeToRemoval, PredictionType.Removal, 60, 20, 100, 40);
        Assert.Equal(50, p.PercentToRemoval);
        Assert.Equal(0, (p with { EstimatedCore = 10 }).PercentToRemoval);
        Assert.Equal(100, (p with { EstimatedCore = 70 }).PercentToRemoval);
        Assert.Null((p with { HeatStart = 60 }).PercentToRemoval);
    }

    [Fact]
    public void PredictionEncodeValidation()
    {
        var p = new PredictionStatus(PredictionState.Predicting, PredictionMode.None, PredictionType.None, 60, 20, 0, 20);
        _ = p.Packed();
        ThrowsAny(() => _ = (p with { Setpoint = 102.4 }).Packed());
        ThrowsAny(() => _ = (p with { HeatStart = -1 }).Packed());
        ThrowsAny(() => _ = (p with { RawSecondsRemaining = 0x20000 }).Packed());
        ThrowsAny(() => _ = (p with { EstimatedCore = 185 }).Packed());

        var sensors = new VirtualSensors(SensorIndex.T1, SensorIndex.T4, SensorIndex.T8);
        var log = new PredictionLog(sensors, PredictionState.Unknown, PredictionMode.Reserved, PredictionType.Reserved, 1, 1, 1);
        _ = log.Packed();
        ThrowsAny(() => _ = (log with { RawSecondsRemaining = 0x20000 }).Packed());
    }

    [Fact]
    public void ReservedPredictionStatesReadAsUnknown()
    {
        for (uint raw = 5; raw <= 15; raw++)
        {
            Assert.Equal(PredictionState.Unknown, PredictionStates.FromRaw(raw));
        }
        Assert.Equal(15u, PredictionState.Unknown.Raw());
        Assert.Equal(102.3, CombustionCodec.MaxPredictionSetpoint);
    }

    [Fact]
    public void SetPredictionData()
    {
        Assert.Equal(1023 | (2 << 10), CombustionCodec.EncodeSetPredictionData(102.3, PredictionMode.RemovalAndResting));
        ThrowsAny(() => CombustionCodec.EncodeSetPredictionData(60, PredictionMode.Reserved));
        ThrowsAny(() => CombustionCodec.EncodeSetPredictionData(102.4, PredictionMode.None));
        ThrowsAny(() => CombustionCodec.EncodeSetPredictionData(-1, PredictionMode.None));
        var decoded = CombustionCodec.DecodeSetPredictionData(650 | (1 << 10));
        Assert.Equal(65, decoded.Setpoint);
        Assert.Equal(PredictionMode.TimeToRemoval, decoded.Mode);
    }

    // Alarms, food safe, session

    [Fact]
    public void AlarmValidation()
    {
        ThrowsAny(() => new AlarmConfig(high: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.Core] = new(true, 799.5) }).Packed());
        ThrowsAny(() => new AlarmConfig(low: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.T1] = new(true, -20.5) }).Packed());
        ThrowsAny(() => new AlarmConfig(low: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.T1] = new(true, double.NaN) }).Packed());
        var bytes = new AlarmConfig(high: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.T1] = new(true, 799) }).Packed();
        Assert.Equal(44, bytes.Length);
        Assert.Equal(8190 << 3 | 1, Le.U16(bytes, 0));
        // Missing channels are sent as unset at -20 C.
        Assert.Equal(0, Le.U16(bytes, 2));
        Assert.Equal(Alarm.Unset, new Alarm(false, -20, false, false));

        // The out-of-range field name matches Swift's "alarm.<kind>.<channel>".
        var ex = Assert.Throws<CodecException>(() => new AlarmConfig(high: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.Core] = new(true, 800) }).Packed());
        Assert.Equal(new CodecError.OutOfRange("alarm.high.core", 800), ex.Error);
    }

    [Fact]
    public void AlarmConfigEquality()
    {
        var a = new AlarmConfig(high: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.T1] = new(true, 50) });
        var b = new AlarmConfig(high: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.T1] = new(true, 50) });
        Assert.True(a == b && a.Equals((object)b) && a.GetHashCode() == b.GetHashCode());
        Assert.True(a != new AlarmConfig());
        Assert.True(a != new AlarmConfig(high: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.T2] = new(true, 50) }));
        Assert.True(a != new AlarmConfig(high: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.T1] = new(true, 51) }));
        Assert.True(default(AlarmConfig) == new AlarmConfig());
        var withLow = new AlarmConfig(low: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.Core] = new(true, 50) });
        Assert.NotEqual(withLow.GetHashCode(), new AlarmConfig().GetHashCode());
        Assert.False(a.Equals("x"));
        Assert.Contains("AlarmConfig", a.ToString());
    }

    [Fact]
    public void FoodSafeValidationAndReservedValues()
    {
        var f = new FoodSafe(FoodSafeMode.Integrated, 1023, FoodSafeServing.CookedAndChilled, 409.55, 0, 1, 2, 25.5, FoodSafeState.Safe, 25.5, 1, 2);
        _ = f.Packed();
        ThrowsAny(() => _ = (f with { Product = 1024 }).Packed());
        ThrowsAny(() => _ = (f with { ThresholdTemp = 409.6 }).Packed());
        ThrowsAny(() => _ = (f with { TargetLogReduction = 25.6 }).Packed());
        ThrowsAny(() => _ = (f with { LogReduction = 26 }).Packed());
        var simplified = (f with { State = FoodSafeState.SafetyImpossible, Mode = FoodSafeMode.Simplified }).Packed();
        // Simplified mode drops integrated values on decode.
        var back = FoodSafe.FromPacked(simplified.Data, simplified.Status);
        Assert.Null(back!.Value.ThresholdTemp);
        Assert.Equal(FoodSafeState.SafetyImpossible, back.Value.State);
        Assert.NotNull(FoodSafe.FromPacked(Zeros(10), Zeros(8)));
        // Reserved mode, serving or state makes the whole food safe block null.
        Assert.Null(FoodSafe.FromPacked([2, 0, 0, 0, 0, 0, 0, 0, 0, 0], Zeros(8)));
        Assert.Null(FoodSafe.FromPacked(Zeros(10), [3, 0, 0, 0, 0, 0, 0, 0]));
        Assert.Null(FoodSafe.FromPacked([0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0], Zeros(8)));
        Assert.False(new SessionInfo(0, 1).IsSupplied);
        Assert.True(new SessionInfo(1, 1).IsSupplied);
    }

    // Status and advertisement encoders

    [Fact]
    public void StatusEncodeNeedsEveryOptionalPart()
    {
        var full = Gen.Status(new SeededRng(7));
        Throws(new CodecError.MissingField("foodSafe"), () => CombustionCodec.EncodeProbeStatus(full with { FoodSafe = null }));
        Throws(new CodecError.MissingField("overheating"), () => CombustionCodec.EncodeProbeStatus(full with { Overheating = null }));
        Throws(new CodecError.MissingField("preferences"), () => CombustionCodec.EncodeProbeStatus(full with { Preferences = null }));
        Throws(new CodecError.MissingField("alarms"), () => CombustionCodec.EncodeProbeStatus(full with { Alarms = null }));
        ThrowsAny(() => CombustionCodec.EncodeProbeStatus(full with { ProbeNumber = 0 }));
        ThrowsAny(() => CombustionCodec.EncodeNodeProbeStatus(new NodeProbeStatus(new ProbeSerial(1), full, 0)));
        ThrowsAny(() => CombustionCodec.EncodeNodeProbeStatus(new NodeProbeStatus(new ProbeSerial(1), full, 5)));
    }

    [Fact]
    public void DecodeStatusLengthErrors()
    {
        Throws(new CodecError.TooShort(30, 29), () => CombustionCodec.DecodeProbeStatus(Zeros(29)));
        Throws(new CodecError.TooShort(35, 34), () => CombustionCodec.DecodeNodeProbeStatus(Zeros(34)));
        Throws(new CodecError.TooShort(53, 40), () => CombustionCodec.DecodeNodeProbeStatus(Zeros(40)));
    }

    [Fact]
    public void AdvertisementEncoderEdgeCases()
    {
        Assert.Equal(new byte[] { 0xC7, 0x09, 9 }, CombustionCodec.EncodeAdvertisement(new AdvertisementPacket.Unknown(9)));
        Assert.Equal(new AdvertisementPacket.Unknown(9), CombustionCodec.DecodeAdvertisement([0xC7, 0x09, 9]));
        ThrowsAny(() => CombustionCodec.EncodeAdvertisement(new AdvertisementPacket.Node(new NodeAdvertisement(NodeProductType.Display, "ELEVENCHARS"))));
        var probe = Gen.ProbeAdvertisement(new SeededRng(3), withPreferences: false);
        ThrowsAny(() => CombustionCodec.EncodeAdvertisement(new AdvertisementPacket.Repeated(probe, 0)));
        ThrowsAny(() => CombustionCodec.EncodeAdvertisement(new AdvertisementPacket.Probe(probe with { ProbeNumber = 9 })));
        // A probe without overheating or preferences encodes to 23 bytes and decodes the same.
        var noOverheat = probe with { Overheating = null };
        var shortBytes = CombustionCodec.EncodeAdvertisement(new AdvertisementPacket.Probe(noOverheat));
        Assert.Equal(23, shortBytes.Length);
        Assert.Equal(new AdvertisementPacket.Probe(noOverheat), CombustionCodec.DecodeAdvertisement(shortBytes));
        // Preferences without overheating: overheating is written as zero.
        var prefs = new ThermometerPreferences(ProbePowerMode.AlwaysOn, false);
        var onlyPrefs = probe with { Overheating = null, Preferences = prefs };
        var decoded = Assert.IsType<AdvertisementPacket.Probe>(CombustionCodec.DecodeAdvertisement(CombustionCodec.EncodeAdvertisement(new AdvertisementPacket.Probe(onlyPrefs))));
        Assert.Equal(SensorSet.Empty, decoded.Advertisement.Overheating);
        Assert.Equal(prefs, decoded.Advertisement.Preferences);
        // Node packet without a preferences byte, and gauge/engine/repeater ignore the byte.
        var node = new byte[10].Prepend((byte)4).Prepend((byte)0x09).Prepend((byte)0xC7).ToArray();
        Assert.Null(((AdvertisementPacket.Node)CombustionCodec.DecodeAdvertisement(node)).Advertisement.Preferences);
        var gauge = new byte[25];
        gauge[0] = 0xC7; gauge[1] = 0x09; gauge[2] = 3; gauge[13] = 7;
        Assert.Null(((AdvertisementPacket.Node)CombustionCodec.DecodeAdvertisement(gauge)).Advertisement.Preferences);
        Assert.Throws<ArgumentException>(() => CombustionCodec.EncodeAdvertisement(null!));
        Throws(new CodecError.BadSync(), () => CombustionCodec.DecodeAdvertisement([0x00, 0x09, 1]));
        Throws(new CodecError.TooShort(3, 2), () => CombustionCodec.DecodeAdvertisement([0xC7, 0x09]));
    }

    // UART encoders and decoders

    [Fact]
    public void FrameEncodingValidation()
    {
        ThrowsAny(() => new UartFrame(UartVariant.Probe, UartDirection.Response, 1, success: true, payload: new byte[256]).Encoded());
        ThrowsAny(() => new UartFrame(UartVariant.Probe, UartDirection.Request, 0x80).Encoded());
        Throws(new CodecError.MissingField("success"), () => new UartFrame(UartVariant.Probe, UartDirection.Response, 1).Encoded());
        Throws(new CodecError.MissingField("requestId"), () => new UartFrame(UartVariant.Node, UartDirection.Request, 1).Encoded());
        Throws(new CodecError.MissingField("responseId"), () => new UartFrame(UartVariant.Node, UartDirection.Response, 1, requestId: 1, success: true).Encoded());
    }

    [Fact]
    public void FrameValueSemantics()
    {
        var a = new UartFrame(UartVariant.Probe, UartDirection.Request, 3, payload: [1, 2]);
        var b = new UartFrame(UartVariant.Probe, UartDirection.Request, 3, payload: [1, 2]);
        Assert.Equal(a, b);
        Assert.Equal(a.GetHashCode(), b.GetHashCode());
        Assert.NotEqual(a, b with { Payload = [1, 3] });
        Assert.Empty(default(UartFrame).Payload);
        Assert.Empty(new UartFrame(UartVariant.Probe, UartDirection.Request, 3).Payload);
        Assert.Contains("0102", a.ToString());
    }

    [Fact]
    public void RequestEncodingValidation()
    {
        Throws(new CodecError.MissingField("probe"), () => CombustionCodec.EncodeRequest(UartVariant.Node, new UartRequest.ReadSessionInfo(), requestId: 1));
        Throws(new CodecError.MissingField("requestId"), () => CombustionCodec.EncodeRequest(UartVariant.Node, new UartRequest.ReadSessionInfo(), new ProbeSerial(1)));
        Throws(new CodecError.UnknownMessageType(0x46), () => CombustionCodec.EncodeRequest(UartVariant.Probe, new UartRequest.ReadProbeFirmware()));
        Throws(new CodecError.UnknownMessageType(0x47), () => CombustionCodec.EncodeRequest(UartVariant.Probe, new UartRequest.ReadProbeHardware()));
        Throws(new CodecError.UnknownMessageType(0x48), () => CombustionCodec.EncodeRequest(UartVariant.Probe, new UartRequest.ReadProbeModel()));
        ThrowsAny(() => CombustionCodec.EncodeRequest(UartVariant.Probe, new UartRequest.SetPrediction(103, PredictionMode.None)));
    }

    private static UartFrame RequestFrame(UartVariant variant, byte type, byte[] payload, UartDirection direction = UartDirection.Request) =>
        new(variant, direction, type, variant == UartVariant.Node ? 1u : null, payload: payload);

    [Fact]
    public void DecodeRequestRejectsWhatItCannotRead()
    {
        Throws(new CodecError.UnknownMessageType(3), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Probe, 3, [], UartDirection.Response)));
        Throws(new CodecError.UnknownMessageType(0x45), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 0x45, [])));
        Throws(new CodecError.UnknownMessageType(0x46), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Probe, 0x46, [])));
        Throws(new CodecError.UnknownMessageType(0x47), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Probe, 0x47, [])));
        Throws(new CodecError.UnknownMessageType(0x48), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Probe, 0x48, [])));
        Throws(new CodecError.TooShort(4, 0), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 3, [])));
        Throws(new CodecError.TooShort(12, 4), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 4, [0, 0, 0, 0])));
        Throws(new CodecError.TooShort(2, 1), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Probe, 5, [0])));
        Throws(new CodecError.TooShort(44, 3), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Probe, 0x0B, [0, 0, 0])));
        Throws(new CodecError.TooShort(16, 2), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 0x0C, [0, 1])));
        Throws(new CodecError.TooShort(4, 0), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 0x46, [])));
        Throws(new CodecError.TooShort(4, 0), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 0x47, [])));
        Throws(new CodecError.TooShort(4, 0), () => CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 0x48, [])));

        // Global silence (flag 1) names no probe.
        var global = RequestFrame(UartVariant.Node, 0x0C, [1, 1, .. new byte[14]]);
        Assert.Null(CombustionCodec.DecodeRequest(global).Probe);
        var targeted = RequestFrame(UartVariant.Node, 0x0C, [0, 1, 0x3F, 0x5A, 0, 0x10, .. new byte[10]]);
        Assert.Equal(new ProbeSerial(0x10005A3F), CombustionCodec.DecodeRequest(targeted).Probe);
        // Node-only reads decode on a node.
        Assert.IsType<UartRequest.ReadProbeFirmware>(CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 0x46, [1, 0, 0, 0])).Request);
        Assert.IsType<UartRequest.ReadProbeHardware>(CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 0x47, [1, 0, 0, 0])).Request);
        Assert.IsType<UartRequest.ReadProbeModel>(CombustionCodec.DecodeRequest(RequestFrame(UartVariant.Node, 0x48, [1, 0, 0, 0])).Request);
    }

    [Fact]
    public void DecodeResponseRejectsWhatItCannotRead()
    {
        Throws(new CodecError.UnknownMessageType(3), () => CombustionCodec.DecodeResponse(new UartFrame(UartVariant.Probe, UartDirection.Request, 3)));
        Throws(new CodecError.UnknownMessageType(0x45), () => CombustionCodec.DecodeResponse(new UartFrame(UartVariant.Probe, UartDirection.Response, 0x45, success: true)));
        // 0x46 is a node-only message: unknown on the probe variant.
        Throws(new CodecError.UnknownMessageType(0x46), () => CombustionCodec.DecodeResponse(new UartFrame(UartVariant.Probe, UartDirection.Response, 0x46, success: true)));
        // A frame built by hand without a success flag counts as failed.
        var noFlag = new UartFrame(UartVariant.Probe, UartDirection.Response, 5);
        Assert.False(CombustionCodec.DecodeResponse(noFlag).Success);
        Throws(new CodecError.TooShort(6, 0), () => CombustionCodec.DecodeResponse(new UartFrame(UartVariant.Probe, UartDirection.Response, 3, success: true)));
        Throws(new CodecError.TooShort(24, 0), () => CombustionCodec.DecodeResponse(new UartFrame(UartVariant.Probe, UartDirection.Response, 4, success: true)));
        Throws(new CodecError.TooShort(24, 0), () => CombustionCodec.DecodeResponse(new UartFrame(UartVariant.Node, UartDirection.Response, 0x46, 1, 2, true)));
    }

    [Fact]
    public void ResponseEncodingValidation()
    {
        var node = new UartResponse(3, true, new ResponseBody.SessionInfoBody(null, new SessionInfo(1, 1)), 1, 2);
        Throws(new CodecError.MissingField("probe"), () => CombustionCodec.EncodeResponse(node, UartVariant.Node));
        var longText = new UartResponse(0x46, true, new ResponseBody.RevisionBody(new ProbeSerial(1), ProbeInfoKind.Firmware, new string('x', 21)), 1, 2);
        ThrowsAny(() => CombustionCodec.EncodeResponse(longText, UartVariant.Node));
        var noIds = new UartResponse(5, true, new ResponseBody.Ack());
        Throws(new CodecError.MissingField("requestId"), () => CombustionCodec.EncodeResponse(noIds, UartVariant.Node));
        Assert.Throws<ArgumentException>(() => CombustionCodec.EncodeResponse(default, UartVariant.Probe));
    }

    [Fact]
    public void MessageTypeConstants()
    {
        Assert.Equal(0x03, new UartRequest.ReadSessionInfo().MessageType);
        Assert.Equal(0x04, new UartRequest.ReadLogs(0, 0).MessageType);
        Assert.Equal(0x05, new UartRequest.SetPrediction(0, PredictionMode.None).MessageType);
        Assert.Equal(0x0B, new UartRequest.SetAlarms(new AlarmConfig()).MessageType);
        Assert.Equal(0x0C, new UartRequest.SilenceAlarms().MessageType);
        Assert.Equal(0x46, new UartRequest.ReadProbeFirmware().MessageType);
        Assert.Equal(0x47, new UartRequest.ReadProbeHardware().MessageType);
        Assert.Equal(0x48, new UartRequest.ReadProbeModel().MessageType);
        Assert.Equal(0x45, UartMessageType.ProbeStatus);
    }

    [Fact]
    public void Node0x45FramesCarryADecodableStatus()
    {
        var rng = new SeededRng(11);
        var node = new NodeProbeStatus(Gen.Serial(rng), Gen.Status(rng), 3);
        var frame = new UartFrame(UartVariant.Node, UartDirection.Request, UartMessageType.ProbeStatus, 9, payload: CombustionCodec.EncodeNodeProbeStatus(node));
        var framer = new UartFramer(UartVariant.Node);
        var received = Assert.IsType<UartFramerOutput.FrameOutput>(framer.Push(frame.Encoded()).First()).Frame;
        Assert.Equal(UartDirection.Request, received.Direction);
        Assert.Equal(0x45, received.MessageType);
        Assert.Equal(node, CombustionCodec.DecodeNodeProbeStatus(received.Payload));
    }

    [Fact]
    public void CodecErrorsAreValueEqualAndPrintable()
    {
        Assert.Equal(new CodecError.BadCrc(1, 2), new CodecError.BadCrc(1, 2));
        Assert.NotEqual<CodecError>(new CodecError.BadSync(), new CodecError.MissingField("x"));
        Assert.Contains("TooShort", new CodecException(new CodecError.TooShort(1, 0)).Message);
    }

    [Fact]
    public void FramerResynchronizesAfterGarbageAndBadCrc()
    {
        var good = new UartFrame(UartVariant.Probe, UartDirection.Response, 5, success: true).Encoded();
        var bad = (byte[])good.Clone();
        bad[2] ^= 0xFF;
        var framer = new UartFramer(UartVariant.Probe);
        var outputs = framer.Push([0x00, 0x01, .. bad, .. good, 0xCA]);
        Assert.IsType<CodecError.BadSync>(Assert.IsType<UartFramerOutput.ErrorOutput>(outputs[0]).Error);
        Assert.IsType<CodecError.BadCrc>(Assert.IsType<UartFramerOutput.ErrorOutput>(outputs[1]).Error);
        Assert.Contains(outputs, o => o is UartFramerOutput.FrameOutput);
        // The trailing 0xCA is kept as a possible start of a sync.
        Assert.Equal(1, framer.BufferedByteCount);
    }

    [Fact]
    public void FramerSkipsAFalseSyncThatSwallowsARealFrame()
    {
        // CA FE 00 00 03 FF claims 255 payload bytes; a real frame follows inside that span.
        var real = new UartFrame(UartVariant.Probe, UartDirection.Response, 3, success: true, payload: [1, 2, 3]).Encoded();
        var framer = new UartFramer(UartVariant.Probe);
        var outputs = framer.Push([0xCA, 0xFE, 0x00, 0x00, 0x03, 0x01, 0xFF, .. real]);
        Assert.Contains(outputs, o => o is UartFramerOutput.FrameOutput f && f.Frame.MessageType == 3 && f.Frame.Payload.SequenceEqual(new byte[] { 1, 2, 3 }));
    }
}
