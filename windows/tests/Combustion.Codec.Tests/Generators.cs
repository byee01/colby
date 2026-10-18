using PS = Combustion.Codec.PredictionState;

namespace Combustion.Codec.Tests;

/// <summary>SplitMix64: small, deterministic and identical on every platform, so a failing seed reproduces anywhere.</summary>
internal sealed class SeededRng
{
    private ulong _state;

    public SeededRng(ulong seed)
    {
        _state = unchecked(seed + 0x9E37_79B9_7F4A_7C15UL);
    }

    public ulong Next()
    {
        unchecked
        {
            _state += 0x9E37_79B9_7F4A_7C15UL;
            var z = _state;
            z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBUL;
            return z ^ (z >> 31);
        }
    }

    public bool Bool() => (Next() & 1) == 1;

    /// <summary>Uniform in the inclusive range.</summary>
    public long Int(long lo, long hi)
    {
        var span = (ulong)(hi - lo) + 1;
        return span == 0 ? (long)Next() : lo + (long)(Next() % span);
    }

    public uint U32(uint lo, uint hi) => (uint)Int(lo, hi);

    public byte Byte(int lo = 0, int hi = 255) => (byte)Int(lo, hi);

    public T Pick<T>(IReadOnlyList<T> items) => items[(int)Int(0, items.Count - 1)];
}

/// <summary>Random but always valid domain values (every one encodes without error).</summary>
internal static class Gen
{
    public static ProbeSerial Serial(SeededRng r) => new(r.U32(0, uint.MaxValue));

    public static ProbeTemperatures Temperatures(SeededRng r) =>
        ProbeTemperatures.FromRaw(Enumerable.Range(0, 8).Select(_ => (ushort)r.Int(0, ProbeTemperatures.MaxRaw)).ToArray());

    public static VirtualSensors VirtualSensors(SeededRng r) =>
        new((SensorIndex)r.Int(0, 5), (SensorIndex)r.Int(3, 6), (SensorIndex)r.Int(4, 7));

    public static SensorSet Sensors(SeededRng r) => new((byte)r.Int(0, 255));

    public static ProbeMode Mode(SeededRng r) => (ProbeMode)r.Int(0, 3);

    public static ProbeColor Color(SeededRng r) => new((byte)r.Int(0, 7));

    public static ThermometerPreferences Preferences(SeededRng r) => ThermometerPreferences.FromByte((byte)r.Int(0, 7));

    public static PredictionState PredictionState(SeededRng r) =>
        r.Pick(new[] { PS.NotInserted, PS.Inserted, PS.Warming,
                       PS.Predicting, PS.RemovalPredictionDone, PS.Unknown });

    public static PredictionStatus Prediction(SeededRng r) => new(
        PredictionState(r), (PredictionMode)r.Int(0, 3), (PredictionType)r.Int(0, 3),
        r.U32(0, 1023) / 10.0, r.U32(0, 1023) / 10.0, r.U32(0, 0x1FFFF), r.U32(0, 2047) / 10.0 - 20);

    public static PredictionLog PredictionLog(SeededRng r) => new(
        VirtualSensors(r), PredictionState(r), (PredictionMode)r.Int(0, 3), (PredictionType)r.Int(0, 3),
        r.U32(0, 1023) / 10.0, r.U32(0, 0x1FFFF), r.U32(0, 2047) / 10.0 - 20);

    public static Alarm Alarm(SeededRng r) => new(r.Bool(), r.U32(0, 8190) / 10.0 - 20, r.Bool(), r.Bool());

    public static AlarmConfig Alarms(SeededRng r)
    {
        var high = new Dictionary<AlarmChannel, Alarm>();
        var low = new Dictionary<AlarmChannel, Alarm>();
        foreach (var channel in Enum.GetValues<AlarmChannel>())
        {
            high[channel] = Alarm(r);
            low[channel] = Alarm(r);
        }
        return new AlarmConfig(high, low);
    }

    public static FoodSafe FoodSafe(SeededRng r)
    {
        var integrated = r.Bool();
        double Fine() => r.U32(0, 8191) * 0.05;
        return new FoodSafe(
            integrated ? FoodSafeMode.Integrated : FoodSafeMode.Simplified,
            (ushort)r.Int(0, 1023),
            r.Bool() ? FoodSafeServing.ServedImmediately : FoodSafeServing.CookedAndChilled,
            integrated ? Fine() : null, integrated ? Fine() : null, integrated ? Fine() : null, integrated ? Fine() : null,
            r.U32(0, 255) / 10.0,
            r.Pick(new[] { FoodSafeState.NotSafe, FoodSafeState.Safe, FoodSafeState.SafetyImpossible }),
            r.U32(0, 255) / 10.0,
            (ushort)r.Int(0, ushort.MaxValue),
            r.U32(0, uint.MaxValue));
    }

    public static SessionInfo Session(SeededRng r) => new(r.U32(1, uint.MaxValue), (ushort)r.Int(0, ushort.MaxValue));

    /// <summary>A complete status (all optional parts present). Session is null half the time (written as zeros).</summary>
    public static ProbeStatusPayload Status(SeededRng r)
    {
        var min = r.U32(0, uint.MaxValue);
        return new ProbeStatusPayload(
            new LogRange(min, r.U32(min, uint.MaxValue)),
            Temperatures(r), Mode(r), Color(r), (int)r.Int(1, 8), r.Bool(), VirtualSensors(r), Prediction(r),
            FoodSafe(r), Sensors(r), Preferences(r), Alarms(r), r.Bool() ? Session(r) : null);
    }

    public static ProbeAdvertisement ProbeAdvertisement(SeededRng r, bool withPreferences) => new(
        Serial(r), Temperatures(r), Mode(r), Color(r), (int)r.Int(1, 8), r.Bool(), VirtualSensors(r),
        Sensors(r), withPreferences ? Preferences(r) : null);

    public static UartRequest Request(SeededRng r, bool node)
    {
        var choices = new List<UartRequest>
        {
            new UartRequest.ReadSessionInfo(),
            new UartRequest.ReadLogs(r.U32(0, uint.MaxValue), r.U32(0, uint.MaxValue)),
            new UartRequest.SetPrediction(r.U32(0, 1023) / 10.0,
                r.Pick(new[] { PredictionMode.None, PredictionMode.TimeToRemoval, PredictionMode.RemovalAndResting })),
            new UartRequest.SetAlarms(Alarms(r)),
            new UartRequest.SilenceAlarms(),
        };
        if (node)
        {
            choices.Add(new UartRequest.ReadProbeFirmware());
            choices.Add(new UartRequest.ReadProbeHardware());
            choices.Add(new UartRequest.ReadProbeModel());
        }
        return r.Pick(choices);
    }

    public static string Text(SeededRng r, int maxLength)
    {
        const string letters = "abcdefghijklmnopqrstuvwxyz0123456789-._|";
        return new string(Enumerable.Range(0, (int)r.Int(0, maxLength)).Select(_ => letters[(int)r.Int(0, letters.Length - 1)]).ToArray());
    }

    public static UartResponse Response(SeededRng r, bool node)
    {
        ProbeSerial? probe = node ? Serial(r) : null;
        var types = new List<byte> { 3, 4, 5, 0x0B, 0x0C, 1, 2, 7, 8, 9, 0x0A };
        if (node)
        {
            types.AddRange([0x46, 0x47, 0x48]);
        }
        var type = r.Pick(types);
        var success = r.Int(0, 4) != 0;
        ResponseBody body = (success, type) switch
        {
            (true, 3) => new ResponseBody.SessionInfoBody(probe, new SessionInfo(r.U32(0, uint.MaxValue), (ushort)r.Int(0, ushort.MaxValue))),
            (true, 4) => new ResponseBody.LogRecordBody(probe, new LogRecord(r.U32(0, uint.MaxValue), Temperatures(r), PredictionLog(r))),
            (true, 0x46) => new ResponseBody.RevisionBody(probe, ProbeInfoKind.Firmware, Text(r, 20)),
            (true, 0x47) => new ResponseBody.RevisionBody(probe, ProbeInfoKind.Hardware, Text(r, 16)),
            (true, 0x48) => new ResponseBody.RevisionBody(probe, ProbeInfoKind.Model, Text(r, 50)),
            _ => new ResponseBody.Ack(),
        };
        return new UartResponse(
            type, success, body,
            node ? r.U32(0, uint.MaxValue) : null,
            node ? r.U32(0, uint.MaxValue) : null);
    }
}
