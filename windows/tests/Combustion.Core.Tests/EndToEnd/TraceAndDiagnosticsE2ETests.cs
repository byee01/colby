using static Combustion.Core.Tests.EndToEnd.E2E;

namespace Combustion.Core.Tests.EndToEnd;

public sealed class TraceAndDiagnosticsE2ETests
{
    [Fact]
    public void TraceRecordsLinkProbeAndSessionEventsInParityFormat() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 10, sessionId: 3);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(10);
        probe.SetInRange(false);
        await rig.RunAsync(10);
        probe.NewSession();
        probe.SetInRange(true);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 30));
        await rig.RunAsync(10);

        var lines = rig.Trace.Lines;
        List<string> Kinds(string k) => [.. lines.Where(l => l.Contains($"\"kind\":\"{k}\""))];
        var links = Kinds("link");
        Assert.Equal(3, links.Count); // connected, disconnected, connected
        Assert.Contains("\"state\":\"connected\"", links[0]);
        Assert.Contains("\"reason\":\"linkLost\"", links[1]);
        var sessions = Kinds("session");
        Assert.Equal(3, sessions.Count); // started 3, ended 3, started 4
        Assert.True(sessions[0].Contains("\"sessionId\":3") && sessions[0].Contains("\"transition\":\"started\""));
        Assert.True(sessions[1].Contains("\"sessionId\":3") && sessions[1].Contains("\"transition\":\"ended\""));
        Assert.True(sessions[2].Contains("\"sessionId\":4") && sessions[2].Contains("\"transition\":\"started\""));
        var probes = Kinds("probe");
        Assert.NotEmpty(probes);
        // Keys sorted, serial uppercase hex, floats at most 2 decimals, state named.
        Assert.StartsWith("{\"core\":", probes[0]);
        Assert.Contains("\"serial\":\"1000000A\"", probes[0]);
        Assert.Contains("\"state\":\"notInserted\"", probes[0]);
        await rig.App.StopAsync();
    });

    [Fact]
    public void DiagnosticsReportCountersAndLinkStates() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 300);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(15);

        var d = rig.App.Diagnostics();
        Assert.Equal(BluetoothState.PoweredOn, d.Bluetooth);
        Assert.Equal(new ValueMap<ProbeSerial, ProbeConnectionState>(new Dictionary<ProbeSerial, ProbeConnectionState>
        {
            [SerialA] = ProbeConnectionState.IsConnected,
        }), d.Links);
        Assert.True(d.Advertisements.ProbePackets > 40);
        Assert.Equal(0, d.Advertisements.CodecErrors);
        Assert.Equal(0, d.StatusDecodeErrors[SerialA]);
        Assert.Equal(new UartDiagnostics(), d.Uart[SerialA]);
        Assert.Equal(0, d.LogFetchesInFlight);

        // Counters outlive the link.
        probe.SetInRange(false);
        await rig.DrainAsync();
        d = rig.App.Diagnostics();
        Assert.True(d.Uart.ContainsKey(SerialA));
        Assert.False(rig.Connected(SerialA));
        await rig.App.StopAsync();
    });

    [Fact]
    public void StartAndStopAreIdempotentAndStopClosesEverything() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 5);
        await rig.App.StartAsync();
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        await rig.RunAsync(10);
        Assert.True(rig.Transport.IsConnected(probe.Peripheral));
        await rig.App.StopAsync();
        await rig.App.StopAsync();
        Assert.False(rig.Transport.IsConnected(probe.Peripheral));
        var attempts = rig.Spy.Attempts.Count;
        await rig.RunAsync(30);
        Assert.Equal(attempts, rig.Spy.Attempts.Count);
        // Can start again.
        await rig.App.StartAsync();
        await rig.RunAsync(20);
        Assert.True(rig.Transport.IsConnected(probe.Peripheral));
        await rig.App.StopAsync();
    });
}
