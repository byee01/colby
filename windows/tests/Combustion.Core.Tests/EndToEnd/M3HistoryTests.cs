using Combustion.Sim;
using static Combustion.Core.Tests.EndToEnd.E2E;

namespace Combustion.Core.Tests.EndToEnd;

/// <summary>M3 exit: connect mid-cook and get the full graph; reconnect after out-of-range without gaps.</summary>
public sealed class M3HistoryTests
{
    private const double Period = 5.0;

    /// <summary>Every seq 0...max present, in order, and each sample's time matches when the probe made it.</summary>
    private static void ExpectComplete(E2ERig rig, SimulatedProbe probe, Func<uint, DateTimeOffset> timeOf, int session = 0)
    {
        var series = rig.Series(probe.Serial, session);
        var max = probe.LogRange.Max;
        Assert.Equal(Contiguous(0, max), series.Samples.Select(s => s.Seq).ToList());
        foreach (var s in series.Samples.Where(s => s.Seq % 50 == 0 || s.Seq == max))
        {
            Assert.True(Math.Abs(s.Time.Since(timeOf(s.Seq))) < 0.5, $"seq {s.Seq}");
        }
        // Content is the probe's own data.
        foreach (var s in series.Samples.Where(s => s.Seq % 97 == 0))
        {
            var r = probe.Record(s.Seq)!.Value;
            Assert.True(Math.Abs(s.Temperatures[0] - r.Temperatures[SensorIndex.T1]) < 0.001);
        }
    }

    private static Func<uint, DateTimeOffset> From(DateTimeOffset at, int seq) =>
        s => at.AddSecondsExact(((int)s - seq) * Period);

    private static List<(uint Start, uint End)> ReadLogs(SimulatedProbe probe) =>
        [.. probe.Requests.OfType<UartRequest.ReadLogs>().Select(r => (r.Start, r.End))];

    [Fact]
    public void FollowMidCookBackfillsEverySeq() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 500);
        var t500 = rig.Clock.Now(); // the moment the probe's latest record (seq 500) was made
        await rig.App.StartAsync();
        await rig.RunAsync(3, step: 1);
        Assert.Empty(await rig.App.History.LoadFollowedAsync());

        await rig.App.FollowAsync(SerialA);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 10));
        // First status after connect arrives within one sample period; then live fetch + backfill.
        await rig.RunAsync(10);
        Assert.True(await rig.EventuallyAsync(() => rig.StoredSeqs(SerialA).Count >= 501));

        ExpectComplete(rig, probe, From(t500, 500));
        var sessions = rig.App.History.Sessions(SerialA);
        Assert.Single(sessions);
        Assert.Equal(1u, sessions[0].Key.SessionId);
        Assert.Equal(Period, sessions[0].SamplePeriod);
        Assert.Null(sessions[0].End);

        // Live from here on: new records arrive one per period, no gaps.
        await rig.RunAsync(60);
        Assert.True(await rig.EventuallyAsync(() => rig.StoredSeqs(SerialA).Count == probe.RecordCount));
        ExpectComplete(rig, probe, From(t500, 500));

        // Backfill requested the old part (the live fetch only asks for the newest 128).
        var reads = ReadLogs(probe);
        var live = reads[0];
        Assert.True(live.End - live.Start + 1 == 128, "the live fetch asks for the newest 128 only");
        Assert.True(live.End >= 500);
        Assert.True(reads[1].End == live.Start - 1, "backfill continues below it, newest first");
        Assert.Contains(reads, r => r.Start == 0);
        await rig.App.StopAsync();
    });

    [Fact]
    public void OutOfRangeThreeMinutesReconnectsWithBackoffAndBackfills() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 100);
        var t100 = rig.Clock.Now();
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(30);
        Assert.True(rig.Connected(SerialA));
        Assert.True(rig.StoredSeqs(SerialA).Count >= 100);
        var connectsBefore = rig.Spy.Attempts.Count;

        // Out of range for 3 minutes of cooking.
        probe.SetInRange(false);
        await rig.DrainAsync();
        var drop = rig.Clock.Monotonic();
        await rig.RunAsync(180);
        Assert.False(rig.Connected(SerialA));
        // Backoff 1, 2, 4, 8, 16, then 30 s steps: attempts at +1, +3, +7, +15, +31, +61, +91 ...
        var attempts = rig.Spy.Attempts.Skip(connectsBefore).Select(t => (t - drop).TotalSeconds).Take(8).ToList();
        ExpectSchedule(attempts, [1, 3, 7, 15, 31, 61, 91, 121]);
        // The probe kept logging meanwhile, so history has a hole right now.
        var mid = rig.StoredSeqs(SerialA);
        Assert.True(probe.LogRange.Max > (mid.Count > 0 ? mid[^1] : 0) + 30);

        probe.SetInRange(true);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 40));
        await rig.RunAsync(30);
        Assert.True(await rig.EventuallyAsync(() => rig.StoredSeqs(SerialA).Count >= probe.RecordCount - 1));
        await rig.RunAsync(10);

        ExpectComplete(rig, probe, From(t100, 100));
        Assert.Single(rig.App.History.Sessions(SerialA));
        await rig.App.StopAsync();
    });

    [Fact]
    public void ChargerRemovalStartsSecondSessionAndClosesFirstWithThumbnail() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 60, sessionId: 7);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(60);
        Assert.True(rig.Connected(SerialA));

        probe.SetInRange(false);
        await rig.RunAsync(20);
        probe.NewSession(); // session 8, log restarts at seq 0
        var t0 = rig.Clock.Now();
        Assert.Equal(8u, probe.SessionId);
        await rig.RunAsync(60);
        probe.SetInRange(true);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 40));
        await rig.RunAsync(30);

        var sessions = rig.App.History.Sessions(SerialA); // newest first
        Assert.Equal([8u, 7u], sessions.Select(s => s.Key.SessionId).ToList());
        Assert.Null(sessions[0].End);
        var closed = sessions[1];
        Assert.NotNull(closed.End);
        Assert.NotEmpty(closed.Thumbnail);
        Assert.True(closed.SampleCount >= 60);

        // The new session holds only the new log, from seq 0, with no gaps.
        ExpectComplete(rig, probe, From(t0, 0), session: 0);
        // The old session was not polluted with the new log.
        var old = rig.StoredSeqs(SerialA, session: 1);
        Assert.Equal(Contiguous(0, old[^1]), old);
        Assert.True(old[^1] < 100);
        await rig.App.StopAsync();
    });

    [Fact]
    public void LegacyFirmwareWithoutSessionIdWorks() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 120);
        probe.LegacyFirmware = true;
        var t120 = rig.Clock.Now();
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(60);
        Assert.True(rig.Connected(SerialA));

        var sessions = rig.App.History.Sessions(SerialA);
        Assert.Single(sessions);
        Assert.Equal(0u, sessions[0].Key.SessionId);
        Assert.Equal(5, sessions[0].SamplePeriod); // default when the status carries none
        Assert.True(await rig.EventuallyAsync(() => rig.StoredSeqs(SerialA).Count == probe.RecordCount));
        ExpectComplete(rig, probe, From(t120, 120));
        var snap = rig.App.Probes.Snapshot(SerialA)!;
        Assert.Null(snap.Session?.Info);
        Assert.Equal(LinkKind.DirectConnection, snap.Link.Primary?.Kind);

        // Fallback session detection: the log restarts (max drops) while the probe was away.
        probe.SetInRange(false);
        await rig.RunAsync(10);
        probe.NewSession();
        probe.SetInRange(true);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 40));
        await rig.RunAsync(20);
        sessions = rig.App.History.Sessions(SerialA);
        Assert.Equal(2, sessions.Count);
        Assert.NotNull(sessions[1].End);
        Assert.Equal(Contiguous(0, probe.LogRange.Max), rig.StoredSeqs(SerialA, session: 0));
        await rig.App.StopAsync();
    });

    [Fact]
    public void UnfollowedProbeIsNeverConnectedOrRecorded() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var a = rig.Probe(SerialA, preload: 10);
        var b = rig.Probe(SerialB, preload: 10);
        try
        {
            await rig.App.StartAsync();
            await rig.App.FollowAsync(SerialA);
            await rig.RunAsync(30);
            Assert.True(rig.Connected(SerialA));
            Assert.True(rig.Transport.IsConnected(new PeripheralId($"PROBE-{SerialA.Hex}")));
            Assert.False(rig.Transport.IsConnected(new PeripheralId($"PROBE-{SerialB.Hex}")));
            Assert.Empty(rig.App.History.Sessions(SerialB));
            Assert.Single(rig.App.History.Sessions(SerialA));

            await rig.App.UnfollowAsync(SerialA);
            await rig.RunAsync(10);
            Assert.False(rig.Transport.IsConnected(new PeripheralId($"PROBE-{SerialA.Hex}")));
            Assert.Empty(rig.App.Diagnostics().Links);
            var attempts = rig.Spy.Attempts.Count;
            await rig.RunAsync(60);
            Assert.Equal(attempts, rig.Spy.Attempts.Count);
            await rig.App.StopAsync();
        }
        finally
        {
            a.Stop();
            b.Stop();
        }
    });
}
