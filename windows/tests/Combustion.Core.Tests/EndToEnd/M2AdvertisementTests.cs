using static Combustion.Core.Tests.EndToEnd.E2E;

namespace Combustion.Core.Tests.EndToEnd;

/// <summary>M2 exit: live 8-sensor temps for all nearby probes, from advertisements alone.</summary>
public sealed class M2AdvertisementTests
{
    [Fact]
    public void ThreeProbesShowEightTempsAndGoOfflineAfterTenSeconds() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var a = rig.Probe(SerialA, preload: 100);
        var b = rig.Probe(SerialB, preload: 200, offset: 5);
        var c = rig.Probe(SerialC, preload: 300, offset: 10);
        await rig.App.StartAsync();
        await rig.RunAsync(2, step: 1);

        Assert.True(await rig.EventuallyAsync(() => rig.App.Probes.Snapshots().Count == 3));
        var snaps = rig.App.Probes.Snapshots();
        foreach (var (serial, probe) in new[] { (SerialA, a), (SerialB, b), (SerialC, c) })
        {
            var s = snaps[serial];
            Assert.Equal(8, s.Temperatures.Count);
            Assert.All(s.Temperatures, t => Assert.NotNull(t));
            Assert.False(s.IsOffline);
            Assert.Equal(LinkKind.Advertisement, s.Link.Primary?.Kind);
            var expected = probe.Record(probe.LogRange.Max)!.Value.Temperatures.Celsius;
            for (var i = 0; i < 8; i++)
            {
                Assert.True(Math.Abs(s.Temperatures[i]!.Value - expected[i]) < 0.06);
            }
        }
        // Different curves, so the probes are told apart.
        Assert.NotEqual(snaps[SerialA].Temperatures[0], snaps[SerialC].Temperatures[0]);

        // Live: temperatures keep moving without any connection.
        var before = snaps[SerialA].Temperatures[7];
        await rig.RunAsync(60, step: 5);
        var after = rig.App.Probes.Snapshot(SerialA)!.Temperatures[7];
        Assert.NotEqual(before, after);
        Assert.Empty(rig.Spy.Attempts); // unfollowed probes are never connected

        // A goes out of range: still shown just before the 10 s source timeout, offline after it.
        a.SetInRange(false);
        await rig.RunAsync(8, step: 1);
        Assert.False(rig.App.Probes.Snapshot(SerialA)!.IsOffline);
        await rig.RunAsync(4, step: 1);
        Assert.True(rig.App.Probes.Snapshot(SerialA)!.IsOffline);
        Assert.False(rig.App.Probes.Snapshot(SerialB)!.IsOffline);
        Assert.False(rig.App.Probes.Snapshot(SerialC)!.IsOffline);

        // And back.
        a.SetInRange(true);
        await rig.RunAsync(1, step: 1);
        Assert.False(rig.App.Probes.Snapshot(SerialA)!.IsOffline);

        var d = rig.App.Diagnostics();
        Assert.Equal(BluetoothState.PoweredOn, d.Bluetooth);
        Assert.True(d.Advertisements.ProbePackets > 100);
        Assert.Equal(0, d.Advertisements.CodecErrors);
        Assert.Empty(d.Links);
        await rig.App.StopAsync();
    });
}
