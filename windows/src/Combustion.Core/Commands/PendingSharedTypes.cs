// Temporary: the alerts port defines these in CommandTypes.cs. Delete this file when merging it.
using Combustion.Codec;

namespace Combustion.Core;

public interface IProbeAlarmSilencing
{
    Task SilenceAlarmsAsync(ProbeSerial serial);
}

public enum AlarmKind { High, Low }
