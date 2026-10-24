using Combustion.Sim;

namespace Combustion.Core.Tests;

using F = StoreFixtures;

/// <summary>
/// Port of <c>mac/Tests/CombustionCoreTests/Links/AdvertisementSourceTests.swift</c>. Only the tests added since the
/// Windows port started are here so far; the rest of the Swift file is listed in docs/HANDOFF.md (parity row 11).
/// </summary>
public sealed class AdvertisementSourceTests
{
    private static readonly ProbeSerial Serial = new(0x1000_5A3F);

    private sealed class Rig
    {
        public Rig()
        {
            Transport = new SimulatedTransport(Clock);
            Source = new AdvertisementSource(Transport);
        }

        public TestClock Clock { get; } = new();

        public SimulatedTransport Transport { get; }

        public AdvertisementSource Source { get; }

        public void Inject(AdvertisementPacket packet, PeripheralId? from = null, int rssi = -60) =>
            Transport.InjectAdvertisement(from ?? new PeripheralId("P"), CombustionCodec.EncodeAdvertisement(packet), rssi);
    }

    [Fact]
    public void EmptySlotFromADisplayIsNotAProbe() => Det.Run(async () =>
    {
        var rig = new Rig();
        using var obs = rig.Source.Observations().Collect();
        using var repeats = rig.Source.RepeatedSightings().Collect();
        await rig.Source.StartAsync();
        // C7 09 02 then 22 zero bytes: captured from a Display in the first 20 s after power-on.
        byte[] empty = [0xC7, 0x09, 0x02, .. new byte[22]];
        rig.Transport.InjectAdvertisement(new PeripheralId("NODE-A"), empty);
        rig.Inject(new AdvertisementPacket.Repeated(F.Advertisement(serial: Serial), 1), new PeripheralId("NODE-A"));
        await rig.Clock.SettleAsync();
        Assert.Equal(Serial, Assert.Single(obs.Items).Serial); // the empty slot published nothing
        Assert.Equal(Serial, Assert.Single(repeats.Items).Serial);
        var d = rig.Source.Diagnostics;
        Assert.Equal(1, d.EmptySlotPackets);
        Assert.Equal(1, d.ProbePackets);
    });
}
