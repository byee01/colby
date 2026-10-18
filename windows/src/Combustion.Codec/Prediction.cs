namespace Combustion.Codec;

/// <summary>Prediction state, 4 bits (probe spec "Prediction State"). Reserved values 5-14 and 15 all read as <c>Unknown</c>.</summary>
public enum PredictionState : byte
{
    NotInserted = 0,
    Inserted = 1,
    Warming = 2,
    Predicting = 3,
    RemovalPredictionDone = 4,
    Unknown = 15,
}

internal static class PredictionStates
{
    public static PredictionState FromRaw(uint raw) => raw switch
    {
        0 => PredictionState.NotInserted,
        1 => PredictionState.Inserted,
        2 => PredictionState.Warming,
        3 => PredictionState.Predicting,
        4 => PredictionState.RemovalPredictionDone,
        _ => PredictionState.Unknown,
    };

    public static uint Raw(this PredictionState state) => (uint)state;
}

/// <summary>Prediction mode, 2 bits. Value 3 is reserved.</summary>
public enum PredictionMode : byte
{
    None = 0,
    TimeToRemoval = 1,
    RemovalAndResting = 2,
    Reserved = 3,
}

/// <summary>Prediction type, 2 bits: what "seconds remaining" counts down to. Value 3 is reserved.</summary>
public enum PredictionType : byte
{
    None = 0,
    Removal = 1,
    Resting = 2,
    Reserved = 3,
}

public static partial class CombustionCodec
{
    /// <summary>Largest prediction set point: 10 bits of 0.1 °C.</summary>
    public const double MaxPredictionSetpoint = 102.3;

    internal static uint Tenths(double value, string field, uint max, double offset = 0) =>
        Scaling.ScaledRaw(value, field, 10, max, offset);

    /// <summary>Set Prediction Data, u16 little-endian (probe spec "Set Prediction Data"): set point 10 bits (0.1 °C), mode 2 bits.</summary>
    internal static ushort EncodeSetPredictionData(double setpoint, PredictionMode mode)
    {
        if (mode == PredictionMode.Reserved)
        {
            throw CodecException.OutOfRange("prediction.mode", (byte)mode);
        }
        var raw = Tenths(setpoint, "prediction.setpoint", 1023);
        return (ushort)(raw | ((uint)mode << 10));
    }

    internal static (double Setpoint, PredictionMode Mode) DecodeSetPredictionData(ushort value) =>
        ((value & 0x3FF) / 10.0, (PredictionMode)((value >> 10) & 0b11));
}

/// <summary>
/// Prediction status, 7 bytes (probe spec "Prediction Status"):
/// state 4, mode 2, type 2, set point 10, heat start 10, seconds 17, estimated core 11 bits.
/// </summary>
/// <param name="Setpoint">°C, 0.1 steps.</param>
/// <param name="HeatStart">°C, core temperature when heating started.</param>
/// <param name="RawSecondsRemaining">As sent by the probe, 0...131071.</param>
/// <param name="EstimatedCore">°C, <c>raw × 0.1 − 20</c>.</param>
public readonly record struct PredictionStatus(
    PredictionState State,
    PredictionMode Mode,
    PredictionType Type,
    double Setpoint,
    double HeatStart,
    uint RawSecondsRemaining,
    double EstimatedCore)
{
    public const int PackedSize = 7;

    /// <summary><c>(estCore − heatStart) / (setpoint − heatStart)</c> as 0...100, null when the span is not positive.</summary>
    public double? PercentToRemoval
    {
        get
        {
            var span = Setpoint - HeatStart;
            if (!(span > 0))
            {
                return null;
            }
            return Math.Min(100, Math.Max(0, (EstimatedCore - HeatStart) / span * 100));
        }
    }

    internal static PredictionStatus FromPacked(ReadOnlySpan<byte> bytes)
    {
        var r = new BitReader(bytes);
        return new PredictionStatus(
            PredictionStates.FromRaw(r.Read(4)),
            (PredictionMode)r.Read(2),
            (PredictionType)r.Read(2),
            r.Read(10) / 10.0,
            r.Read(10) / 10.0,
            r.Read(17),
            r.Read(11) / 10.0 - 20);
    }

    public byte[] Packed()
    {
        var w = new BitWriter(PackedSize);
        w.Write(State.Raw(), 4);
        w.Write((uint)Mode, 2);
        w.Write((uint)Type, 2);
        w.Write(CombustionCodec.Tenths(Setpoint, "prediction.setpoint", 1023), 10);
        w.Write(CombustionCodec.Tenths(HeatStart, "prediction.heatStart", 1023), 10);
        if (RawSecondsRemaining > 0x1FFFF)
        {
            throw CodecException.OutOfRange("prediction.seconds", RawSecondsRemaining);
        }
        w.Write(RawSecondsRemaining, 17);
        w.Write(CombustionCodec.Tenths(EstimatedCore, "prediction.estimatedCore", 2047, offset: 20), 11);
        return w.Bytes;
    }
}

/// <summary>
/// Prediction log, 7 bytes inside log records (probe spec "Prediction Log"):
/// virtual sensors 7, state 4, mode 2, type 2, set point 10, seconds 17, estimated core 11 bits, 3 reserved.
/// </summary>
public readonly record struct PredictionLog(
    VirtualSensors VirtualSensors,
    PredictionState State,
    PredictionMode Mode,
    PredictionType Type,
    double Setpoint,
    uint RawSecondsRemaining,
    double EstimatedCore)
{
    public const int PackedSize = 7;

    internal static PredictionLog FromPacked(ReadOnlySpan<byte> bytes)
    {
        var r = new BitReader(bytes);
        return new PredictionLog(
            VirtualSensors.FromBits(r.Read(7)),
            PredictionStates.FromRaw(r.Read(4)),
            (PredictionMode)r.Read(2),
            (PredictionType)r.Read(2),
            r.Read(10) / 10.0,
            r.Read(17),
            r.Read(11) / 10.0 - 20);
    }

    public byte[] Packed()
    {
        var w = new BitWriter(PackedSize);
        w.Write(VirtualSensors.Bits, 7);
        w.Write(State.Raw(), 4);
        w.Write((uint)Mode, 2);
        w.Write((uint)Type, 2);
        w.Write(CombustionCodec.Tenths(Setpoint, "predictionLog.setpoint", 1023), 10);
        if (RawSecondsRemaining > 0x1FFFF)
        {
            throw CodecException.OutOfRange("predictionLog.seconds", RawSecondsRemaining);
        }
        w.Write(RawSecondsRemaining, 17);
        w.Write(CombustionCodec.Tenths(EstimatedCore, "predictionLog.estimatedCore", 2047, offset: 20), 11);
        return w.Bytes;
    }
}
