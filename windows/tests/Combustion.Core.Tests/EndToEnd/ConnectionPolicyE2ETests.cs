using Combustion.Sim;
using static Combustion.Core.Tests.EndToEnd.E2E;

namespace Combustion.Core.Tests.EndToEnd;

/// <summary>docs/02 §5.6, direct-only: backoff 1, 2, 4 ... 30 s; give up after 5 min absent; resume on reappearance.</summary>
public sealed class ConnectionPolicyE2ETests
{
    [Fact]
    public void GivesUpAfterFiveMinutesAbsentAndResumesWhenItReappears() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 30);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(20);
        Assert.True(rig.Connected(SerialA));

        probe.SetInRange(false);
        await rig.DrainAsync();
        var left = rig.Clock.Monotonic();

        // Still trying just before the limit ...
        await rig.RunAsync(290);
        Assert.IsType<ProbeConnectionState.Backoff>(rig.LinkState(SerialA));
        // ... and gives up at 5 min.
        await rig.RunAsync(15);
        Assert.IsType<ProbeConnectionState.GaveUp>(rig.LinkState(SerialA));
        var attempts = rig.Spy.Attempts.Where(t => t > left).Select(t => (t - left).TotalSeconds).ToList();
        ExpectSchedule(attempts, [1, 3, 7, 15, 31, 61, 91, 121, 151, 181, 211, 241, 271]);
        Assert.All(attempts, t => Assert.True(t < 300));

        // Stays given up (no more connects) while absent.
        var count = rig.Spy.Attempts.Count;
        await rig.RunAsync(240);
        Assert.Equal(count, rig.Spy.Attempts.Count);
        Assert.IsType<ProbeConnectionState.GaveUp>(rig.LinkState(SerialA));

        // Reappears: resumes at once (no backoff wait) and backfills the 9 minutes it missed.
        probe.SetInRange(true);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 5));
        Assert.Equal(count + 1, rig.Spy.Attempts.Count);
        await rig.RunAsync(20);
        Assert.Equal(Contiguous(0, probe.LogRange.Max), rig.StoredSeqs(SerialA));
        Assert.True(probe.LogRange.Max > 30 + 100);
        await rig.App.StopAsync();
    });

    [Fact]
    public void RefusedConnectsBackOffThenSucceed() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 5);
        rig.Transport.RefuseConnects(3);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(20);
        Assert.True(rig.Connected(SerialA));
        // Heard at t=0.25; refused at once, then +1, +2, +4 later it works.
        var first = rig.Spy.Attempts[0];
        ExpectSchedule([.. rig.Spy.Attempts.Select(t => (t - first).TotalSeconds)], [0, 1, 3, 7]);
        probe.Stop();
        await rig.App.StopAsync();
    });

    [Fact]
    public void ConnectTimeoutCountsAsFailureAndBacksOff() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 5);
        rig.Transport.SetConnectDelay(TimeSpan.FromSeconds(30)); // longer than the 10 s connect timeout
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(10);
        var connecting = Assert.IsType<ProbeConnectionState.Connecting>(rig.LinkState(SerialA));
        Assert.Equal(1, connecting.Attempt);
        await rig.RunAsync(1); // timed out at 10.25 s, now waiting 1 s
        var backoff = Assert.IsType<ProbeConnectionState.Backoff>(rig.LinkState(SerialA));
        Assert.True(backoff.RetryAt > rig.Clock.Monotonic());
        rig.Transport.SetConnectDelay(TimeSpan.Zero);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 60));
        probe.Stop();
        await rig.App.StopAsync();
    });

    [Fact]
    public void OneConnectionPerProbeAndNoReconnectChurnWhileConnected() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var a = rig.Probe(SerialA, preload: 5);
        var b = rig.Probe(SerialB, preload: 5);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.App.FollowAsync(SerialB);
        await rig.RunAsync(20);
        Assert.True(rig.Connected(SerialA));
        Assert.True(rig.Connected(SerialB));
        Assert.Equal(2, rig.Spy.Attempts.Count);
        // Following twice or re-following changes nothing.
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(120);
        Assert.Equal(2, rig.Spy.Attempts.Count);
        a.Stop();
        b.Stop();
        await rig.App.StopAsync();
        Assert.False(rig.Transport.IsConnected(a.Peripheral));
        Assert.False(rig.Transport.IsConnected(b.Peripheral));
    });

    [Fact]
    public void BluetoothOffDropsLinksAndComesBackWithScanning() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 20);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(20);
        Assert.True(rig.Connected(SerialA));

        rig.Transport.SetState(BluetoothState.PoweredOff);
        await rig.RunAsync(20);
        Assert.Equal(BluetoothState.PoweredOff, rig.App.Diagnostics().Bluetooth);
        Assert.False(rig.Connected(SerialA));

        rig.Transport.SetState(BluetoothState.PoweredOn);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 60));
        await rig.RunAsync(20);
        Assert.Equal(BluetoothState.PoweredOn, rig.App.Diagnostics().Bluetooth);
        Assert.Equal(Contiguous(0, probe.LogRange.Max), rig.StoredSeqs(SerialA));
        await rig.App.StopAsync();
    });

    [Fact]
    public void FollowedSetSurvivesRestartThroughTheDatabase() => Det.Run(async () =>
    {
        var path = Path.Combine(Path.GetTempPath(), $"colby-e2e-{Guid.NewGuid()}.sqlite");
        try
        {
            {
                var clock = new TestClock();
                using var first = new CombustionApp(new SimulatedTransport(clock), clock, databasePath: path);
                await first.FollowAsync(SerialA);
            }
            var clock2 = new TestClock();
            using var app = new CombustionApp(new SimulatedTransport(clock2), clock2, databasePath: path);
            await app.StartAsync();
            Assert.Equal(new HashSet<ProbeSerial> { SerialA }, app.Probes.FollowedSerials());
            await app.StopAsync();
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            File.Delete(path);
        }
    });
}
