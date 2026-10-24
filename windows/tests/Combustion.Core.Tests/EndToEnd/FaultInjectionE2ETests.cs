using Combustion.Sim;
using static Combustion.Core.Tests.EndToEnd.E2E;

namespace Combustion.Core.Tests.EndToEnd;

/// <summary>Lossy links and mid-download disconnects must still end in a complete history.</summary>
public sealed class FaultInjectionE2ETests
{
    private static List<(uint Start, uint End)> ReadRanges(SimulatedProbe probe) =>
        [.. probe.Requests.OfType<UartRequest.ReadLogs>().Select(r => (r.Start, r.End))];

    [Fact]
    public void NotificationsDroppedDuringDownloadAreFilledByTheNextBackfillPass() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 300);
        // The live fetch takes 128 responses (173...300 or so). Then the first backfill chunk starts:
        // let 40 of its records through and lose the next 3.
        rig.Transport.DropNextNotifications(3, after: 128 + 40, on: GattUuid.UartTx);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(5);
        Assert.True(rig.Connected(SerialA));
        await rig.RunAsync(30);

        Assert.Equal(Contiguous(0, probe.LogRange.Max), rig.StoredSeqs(SerialA));
        // The hole was requested twice: once lost, once recovered.
        var ranges = ReadRanges(probe);
        var live = ranges[0];
        var lostSeq = live.Start - 128 + 40; // first record of the backfill chunk below `live`
        var hits = ranges.Count(r => r.Start <= lostSeq && lostSeq <= r.End);
        Assert.True(hits >= 2, $"seq {lostSeq} requested {hits} times in [{string.Join(", ", ranges)}]");
        Assert.Equal(0, rig.App.Diagnostics().LogFetchesInFlight);
        await rig.App.StopAsync();
    });

    [Fact]
    public void DroppedLiveRecordIsRepairedByThePeriodicCheck() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 20);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(30);
        Assert.True(rig.Connected(SerialA));
        Assert.Equal(Contiguous(0, probe.LogRange.Max), rig.StoredSeqs(SerialA));

        // Lose one status, so the next live fetch asks for two records, then lose the first response.
        // The stored max moves past the hole and only the periodic recheck can repair it.
        rig.Transport.DropNextNotifications(1, on: GattUuid.ProbeStatus);
        await rig.RunAsync(5);
        rig.Transport.DropNextNotifications(1, on: GattUuid.UartTx);
        await rig.RunAsync(5);
        Assert.True(rig.StoredSeqs(SerialA).Count == (int)probe.LogRange.Max, "exactly one record is missing right now");
        // Within the next minute the connected-state recheck fills it.
        await rig.RunAsync(70);
        Assert.Equal(Contiguous(0, probe.LogRange.Max), rig.StoredSeqs(SerialA));
        await rig.App.StopAsync();
    });

    [Fact]
    public void DisconnectMidDownloadCompletesAfterReconnect() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 300);
        probe.DropLinkAfterLogRecords(50); // first Read Logs: 50 records, then the link drops
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(6);
        // The partial download was kept.
        Assert.Equal(51, rig.StoredSeqs(SerialA).Count); // 50 records plus the status's own
        Assert.False(rig.Connected(SerialA));

        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 30));
        await rig.RunAsync(30);
        Assert.Equal(Contiguous(0, probe.LogRange.Max), rig.StoredSeqs(SerialA));
        Assert.Single(rig.App.History.Sessions(SerialA));
        // Two connections were made (the second after backoff).
        Assert.Equal(2, rig.Spy.Attempts.Count);
        await rig.App.StopAsync();
    });

    [Fact]
    public void DuplicatedNotificationsDoNotDuplicateSamples() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 200);
        rig.Transport.DuplicateNextNotifications(100, on: GattUuid.UartTx);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(30);
        Assert.Equal(Contiguous(0, probe.LogRange.Max), rig.StoredSeqs(SerialA));
        await rig.App.StopAsync();
    });
}
