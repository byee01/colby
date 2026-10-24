using Combustion.Sim;
using static Combustion.Core.Tests.EndToEnd.E2E;

namespace Combustion.Core.Tests.EndToEnd;

public static class NodeRig
{
    public const string DisplayD = "DISPLAY001";

    public static SimulatedNode Node(this E2ERig rig, string serial = DisplayD, IEnumerable<SimulatedProbe>? relaying = null, int hops = 1)
    {
        var n = new SimulatedNode(serial, rig.Transport, rig.Clock);
        foreach (var p in relaying ?? [])
        {
            n.Relay(p, hops);
        }
        n.Start();
        return n;
    }

    public static bool NodeConnected(this E2ERig rig, string serial = DisplayD) =>
        rig.App.Diagnostics().NodeLinks.TryGetValue(serial, out var s) && s is ProbeConnectionState.Connected;

    public static ProbeSnapshot? Snapshot(this E2ERig rig, ProbeSerial serial) => rig.App.Probes.Snapshot(serial);

    public static int ReadLogCount(SimulatedProbe probe) => probe.Requests.OfType<UartRequest.ReadLogs>().Count();
}

/// <summary>M4 exit: a probe out of the Mac's range but in the Display's range still updates and backfills via the node.</summary>
public sealed class M4MeatNetTests
{
    private const double Period = 5.0;
    private const string DisplayD = NodeRig.DisplayD;
    private static readonly ProbeConnectionState ViaDisplay = new ProbeConnectionState.ViaNode(DisplayD);

    [Fact]
    public void ProbeLeavesMacRangeButStaysInDisplayRangeAndBackfillsViaNode() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 60);
        var t60 = rig.Clock.Now();
        var display = rig.Node(relaying: [probe]);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(30);
        // Node first: the Display covers the probe, so the probe's connection slot stays free.
        Assert.True(rig.NodeConnected());
        Assert.Equal(ViaDisplay, rig.LinkState(SerialA));
        Assert.False(rig.Transport.IsConnected(probe.Peripheral));
        Assert.True(rig.StoredSeqs(SerialA).Count >= 60);

        // Out of the Mac's range for 3 minutes of cooking; the Display still hears the probe.
        probe.SetInRange(false);
        await rig.DrainAsync();
        await rig.RunAsync(180);

        // Live data arrives through the node.
        var snap = rig.Snapshot(SerialA)!;
        var primary = snap.Link.Primary!;
        Assert.Equal(LinkKind.NodeConnection, primary.Kind);
        Assert.Equal(DisplayD, primary.Via);
        Assert.Equal(1, primary.HopCount);
        Assert.False(snap.IsOffline);
        var record = probe.Record(probe.LogRange.Max)!.Value;
        Assert.True(Math.Abs((snap.Temperatures[0] ?? 0) - record.Temperatures[SensorIndex.T1]) < 0.1);
        Assert.True(Math.Abs(snap.ReceivedAt.Since(rig.Clock.Now())) < 10);

        // History is complete, filled through the node: the probe itself saw no Read Logs at all.
        Assert.True(await rig.EventuallyAsync(() => rig.StoredSeqs(SerialA).Count >= probe.RecordCount - 1));
        var seqs = rig.StoredSeqs(SerialA);
        Assert.Equal(Contiguous(0, seqs[^1]), seqs);
        Assert.True(seqs[^1] >= probe.LogRange.Max - 1);
        Assert.Equal(0, NodeRig.ReadLogCount(probe));
        var nodeReads = display.Requests.Where(r => r.Request is UartRequest.ReadLogs).ToList();
        Assert.NotEmpty(nodeReads);
        Assert.All(nodeReads, r => Assert.Equal(SerialA, r.Probe));
        // Times line up with when the probe made the samples.
        var sample = rig.Series(SerialA).Samples.First(s => s.Seq == 100);
        Assert.True(Math.Abs(sample.Time.Since(t60.AddSecondsExact(40 * Period))) < 1.5);

        await rig.App.StopAsync();
        Assert.False(rig.Transport.IsConnected(display.Peripheral));
    });

    [Fact]
    public void ProbeNeverInMacRangeIsFollowedBackfilledAndLiveThroughNode() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 200);
        probe.SetInRange(false);
        var display = rig.Node(relaying: [probe], hops: 2);
        display.SetDeviceInfo(new DeviceInfo("v2.0.1", "rev C", "Display"));
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(2, step: 1);
        // Only the Display's repeated advertisement is heard, so the probe shows up (offline of any connection).
        Assert.Equal(ProbeConnectionState.Waiting, rig.LinkState(SerialA));
        Assert.Equal(LinkKind.NodeAdvertisement, rig.Snapshot(SerialA)!.Link.Primary?.Kind);

        Assert.True(await rig.RunUntilAsync(() => rig.NodeConnected(), limit: 30));
        await rig.RunAsync(40);
        Assert.Equal(ProbeConnectionState.Waiting, rig.LinkState(SerialA));
        Assert.Equal(Contiguous(0, probe.LogRange.Max), rig.StoredSeqs(SerialA));
        var snap = rig.Snapshot(SerialA)!;
        Assert.Equal(LinkKind.NodeConnection, snap.Link.Primary?.Kind);
        Assert.Equal(2, snap.Link.Primary?.HopCount);
        Assert.Equal(1u, snap.Session?.Info?.SessionId);

        // The node itself is visible to the UI.
        var node = rig.App.Probes.NodeSnapshots()[DisplayD];
        Assert.True(node.IsConnected);
        Assert.Equal(NodeProductType.Display, node.ProductType);
        Assert.Equal([SerialA], node.Probes.ToList());
        Assert.Equal(2, node.HopCounts[SerialA]);
        Assert.Single(node.HopCounts);
        Assert.Equal(new DeviceInfo("v2.0.1", "rev C", "Display"), node.Firmware);
        Assert.True(node.HeartbeatCount > 10);
        Assert.Equal(LinkKind.DirectConnection, node.Link.Kind);
        await rig.App.StopAsync();
    });

    [Fact]
    public void ProbeComingBackInMacRangeStaysOnTheNodeAndOpensNoDirectLink() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 40);
        probe.SetInRange(false);
        _ = rig.Node(relaying: [probe]);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        Assert.True(await rig.RunUntilAsync(() => rig.NodeConnected(), limit: 30));
        await rig.RunAsync(30);
        Assert.Equal(LinkKind.NodeConnection, rig.Snapshot(SerialA)!.Link.Primary?.Kind);

        probe.SetInRange(true);
        await rig.RunAsync(60);
        // The node covers the probe, so its slot stays free: no direct connection is ever opened.
        Assert.True(rig.NodeConnected());
        Assert.False(rig.Transport.IsConnected(probe.Peripheral));
        Assert.True(rig.Spy.Attempts.Count == 1, "only the node was connected");
        Assert.Equal(ViaDisplay, rig.LinkState(SerialA));
        var snap = rig.Snapshot(SerialA)!;
        Assert.Equal(LinkKind.NodeConnection, snap.Link.Primary?.Kind);
        Assert.True(snap.Link.Sources.Any(s => s.Kind == LinkKind.Advertisement), "its own advertisements are still heard");
        Assert.True(await rig.EventuallyAsync(() => rig.StoredSeqs(SerialA).Count >= probe.RecordCount - 1));
        var seqs = rig.StoredSeqs(SerialA);
        Assert.Equal(Contiguous(0, seqs[^1]), seqs);
        await rig.App.StopAsync();
    });

    [Fact]
    public void NodeDropFallsBackToDirectAndTheNodeTakesOverAgain() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 30);
        var display = rig.Node(relaying: [probe]);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        Assert.True(await rig.RunUntilAsync(() => rig.NodeConnected(), limit: 30));
        await rig.RunAsync(20);
        Assert.False(rig.Transport.IsConnected(probe.Peripheral));

        // The Display goes away: the probe falls back to a direct connection and history keeps filling.
        display.SetInRange(false);
        await rig.DrainAsync();
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 60));
        await rig.RunAsync(40);
        Assert.False(rig.NodeConnected());
        Assert.Equal(LinkKind.DirectConnection, rig.Snapshot(SerialA)!.Link.Primary?.Kind);
        Assert.True(await rig.EventuallyAsync(() => rig.StoredSeqs(SerialA).Count >= probe.RecordCount - 1));
        Assert.True(NodeRig.ReadLogCount(probe) > 0, "the hole was backfilled over the direct link");

        // The Display returns: the node takes over and the direct link is released.
        display.SetInRange(true);
        Assert.True(await rig.RunUntilAsync(() => rig.NodeConnected(), limit: 40));
        await rig.RunAsync(30);
        Assert.False(rig.Transport.IsConnected(probe.Peripheral));
        Assert.Equal(ViaDisplay, rig.LinkState(SerialA));
        Assert.Equal(LinkKind.NodeConnection, rig.Snapshot(SerialA)!.Link.Primary?.Kind);
        Assert.True(await rig.EventuallyAsync(() => rig.StoredSeqs(SerialA).Count >= probe.RecordCount - 1));
        var seqs = rig.StoredSeqs(SerialA);
        Assert.Equal(Contiguous(0, seqs[^1]), seqs);
        await rig.App.StopAsync();
    });

    [Fact]
    public void NodeDropsAndComesBackWithBackoffAndTheProbeKeepsFillingIn() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 20);
        probe.SetInRange(false);
        var display = rig.Node(relaying: [probe]);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        Assert.True(await rig.RunUntilAsync(() => rig.NodeConnected(), limit: 30));
        await rig.RunAsync(20);

        display.SetInRange(false); // the Display is switched off / carried away
        await rig.DrainAsync();
        await rig.RunAsync(60);
        Assert.False(rig.App.Diagnostics().NodeLinks.ContainsKey(DisplayD), "nothing relays the probe, so the policy stops trying");
        Assert.False(rig.NodeConnected());
        var during = rig.StoredSeqs(SerialA);
        Assert.True(probe.LogRange.Max > (during.Count > 0 ? during[^1] : 0) + 5);
        Assert.True(rig.Snapshot(SerialA)!.IsOffline);

        display.SetInRange(true);
        Assert.True(await rig.RunUntilAsync(() => rig.NodeConnected(), limit: 40));
        await rig.RunAsync(40);
        Assert.True(await rig.EventuallyAsync(() => rig.StoredSeqs(SerialA).Count >= probe.RecordCount - 1));
        var seqs = rig.StoredSeqs(SerialA);
        Assert.Equal(Contiguous(0, seqs[^1]), seqs);
        await rig.App.StopAsync();
    });

    [Fact]
    public void NodeSeenButNothingFollowedIsNeverConnected() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 10);
        probe.SetInRange(false);
        var display = rig.Node(relaying: [probe]);
        await rig.App.StartAsync();
        await rig.RunAsync(30);
        Assert.False(rig.Transport.IsConnected(display.Peripheral));
        var node = rig.App.Probes.NodeSnapshots()[DisplayD];
        Assert.False(node.IsConnected);
        Assert.Equal(LinkKind.NodeAdvertisement, node.Link.Kind);
        Assert.Empty(node.Probes);
        // The probe's live temperature is still visible from the repeated advertisement alone.
        Assert.Equal(LinkKind.NodeAdvertisement, rig.Snapshot(SerialA)!.Link.Primary?.Kind);

        // Unfollowing closes a node connection that was only there for that probe.
        await rig.App.FollowAsync(SerialA);
        Assert.True(await rig.RunUntilAsync(() => rig.NodeConnected(), limit: 30));
        await rig.App.UnfollowAsync(SerialA);
        await rig.RunAsync(5);
        Assert.False(rig.Transport.IsConnected(display.Peripheral));
        await rig.App.StopAsync();
    });
}
