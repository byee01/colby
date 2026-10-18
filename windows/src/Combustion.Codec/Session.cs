namespace Combustion.Codec;

/// <summary>Range of log sequence numbers held by the probe (two u32, min then max).</summary>
public readonly record struct LogRange(uint Min, uint Max);

/// <summary>
/// Session ID (u32) and log sample period (u16 ms). Probe spec "Session ID".
/// Status decoders return null instead of a <see cref="SessionInfo"/> with <c>SessionId == 0</c> (0 means "not supplied");
/// the Read Session Information response reports the raw value.
/// </summary>
public readonly record struct SessionInfo(uint SessionId, ushort SamplePeriodMs)
{
    /// <summary><c>SessionId == 0</c> is the reserved "not supplied" value.</summary>
    public bool IsSupplied => SessionId != 0;
}
