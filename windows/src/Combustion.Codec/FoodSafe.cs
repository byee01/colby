namespace Combustion.Codec;

public enum FoodSafeMode { Simplified, Integrated }

public enum FoodSafeServing { ServedImmediately, CookedAndChilled }

public enum FoodSafeState { NotSafe, Safe, SafetyImpossible }

/// <summary>
/// Food Safe Data (10 bytes) plus Food Safe Status (8 bytes), read-only in v1.
/// <para>
/// Data bits: mode 3, product 10, serving 3, threshold 13, z-value 13, reference temp 13, D-value 13,
/// target log reduction 8 (probe spec "Food Safe Data"). The four 13-bit values are <c>raw × 0.05</c>.
/// Status bits: state 3, log reduction 8 (<c>raw × 0.1</c>), seconds above threshold 16, log sequence 32.
/// </para>
/// </summary>
/// <param name="Product">Enum differs by mode; the UI maps it to a label.</param>
/// <param name="ThresholdTemp">Integrated mode only; null in simplified mode.</param>
/// <param name="LogReduction">0 in simplified mode.</param>
public readonly record struct FoodSafe(
    FoodSafeMode Mode,
    ushort Product,
    FoodSafeServing Serving,
    double? ThresholdTemp = null,
    double? ZValue = null,
    double? ReferenceTemp = null,
    double? DValue = null,
    double TargetLogReduction = 0,
    FoodSafeState State = FoodSafeState.NotSafe,
    double LogReduction = 0,
    ushort SecondsAboveThreshold = 0,
    uint LogSequence = 0)
{
    public const int DataSize = 10;
    public const int StatusSize = 8;

    /// <summary>
    /// Returns null for reserved mode, serving or state values (the Android SDK does the same),
    /// so a newer probe never breaks the rest of the status.
    /// </summary>
    internal static FoodSafe? FromPacked(ReadOnlySpan<byte> data, ReadOnlySpan<byte> status)
    {
        var d = new BitReader(data);
        var rawMode = d.Read(3);
        var rawProduct = d.Read(10);
        var rawServing = d.Read(3);
        var threshold = d.Read(13) * 0.05;
        var z = d.Read(13) * 0.05;
        var reference = d.Read(13) * 0.05;
        var dValue = d.Read(13) * 0.05;
        var target = d.Read(8) / 10.0;

        var s = new BitReader(status);
        var rawState = s.Read(3);
        var reduction = s.Read(8) / 10.0;
        var seconds = s.Read(16);
        var sequence = s.Read(32);

        if (!(rawMode <= 1 && rawServing <= 1 && rawState <= 2))
        {
            return null;
        }
        var integrated = rawMode == 1;
        return new FoodSafe(
            integrated ? FoodSafeMode.Integrated : FoodSafeMode.Simplified,
            (ushort)rawProduct,
            rawServing == 0 ? FoodSafeServing.ServedImmediately : FoodSafeServing.CookedAndChilled,
            integrated ? threshold : null,
            integrated ? z : null,
            integrated ? reference : null,
            integrated ? dValue : null,
            target,
            (FoodSafeState)rawState,
            reduction,
            (ushort)seconds,
            sequence);
    }

    /// <summary>Packs back into the two wire fields. Integrated values must fit 13 bits at 0.05 (0...409.55).</summary>
    public (byte[] Data, byte[] Status) Packed()
    {
        static uint Fine(double? value, string field) => Scaling.ScaledRaw(value ?? 0, field, 20, 0x1FFF);

        if (Product > 0x3FF)
        {
            throw CodecException.OutOfRange("foodSafe.product", Product);
        }
        var d = new BitWriter(DataSize);
        d.Write(Mode == FoodSafeMode.Simplified ? 0u : 1u, 3);
        d.Write(Product, 10);
        d.Write(Serving == FoodSafeServing.ServedImmediately ? 0u : 1u, 3);
        d.Write(Fine(ThresholdTemp, "foodSafe.thresholdTemp"), 13);
        d.Write(Fine(ZValue, "foodSafe.zValue"), 13);
        d.Write(Fine(ReferenceTemp, "foodSafe.referenceTemp"), 13);
        d.Write(Fine(DValue, "foodSafe.dValue"), 13);
        d.Write(Scaling.ScaledRaw(TargetLogReduction, "foodSafe.targetLogReduction", 10, 255), 8);

        var s = new BitWriter(StatusSize);
        s.Write(State == FoodSafeState.NotSafe ? 0u : State == FoodSafeState.Safe ? 1u : 2u, 3);
        s.Write(Scaling.ScaledRaw(LogReduction, "foodSafe.logReduction", 10, 255), 8);
        s.Write(SecondsAboveThreshold, 16);
        s.Write(LogSequence, 32);
        return (d.Bytes, s.Bytes);
    }
}
