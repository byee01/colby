using Combustion.Codec;

namespace Combustion.Core;

// The small types of mac/Sources/CombustionCore/Commands/Commands.swift that the alert engine needs.
// The Commands class itself is ported separately.

/// <summary>What the alert engine needs from <c>Commands</c>.</summary>
public interface IProbeAlarmSilencing
{
    Task SilenceAlarmsAsync(ProbeSerial serial);
}

public enum AlarmKind { High, Low }
