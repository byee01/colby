using static Combustion.Sim.Tests.Sim;

namespace Combustion.Sim.Tests;

public class ReplayAndRecordingTests
{
    private static readonly string UartTx = GattUuid.UartTx.Raw;
    private static readonly string UartRx = GattUuid.UartRx.Raw;
    private static readonly string Status = GattUuid.ProbeStatus.Raw;

    [Fact]
    public void ReplayDeliversTimelineOnClockTime() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock);
        await sim.StartScanAsync();
        var advs = sim.Advertisements();
        _ = sim.StartReplay(
        [
            new ReplayEvent(1, ReplayEvent.Kind.Adv, Peripheral: "PROBE-A", Hex: "01"),
            new ReplayEvent(2, ReplayEvent.Kind.Adv, Peripheral: "PROBE-A", Hex: "02"),
            new ReplayEvent(2, ReplayEvent.Kind.Adv, Peripheral: "PROBE-A", Hex: "03"),
        ]);
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(1500));
        Assert.Equal([1], (await advs.NextItem())?.MfrData);
        Assert.Equal(0, advs.BufferedCount);
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(500));
        Assert.Equal([2], (await advs.NextItem())?.MfrData);
        Assert.Equal([3], (await advs.NextItem())?.MfrData);
    });

    [Fact]
    public void ReplayStateAndDisconnectEvents() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock);
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
        var disc = c.Disconnected();
        var states = sim.State();
        Assert.Equal(BluetoothState.PoweredOn, await states.NextValue());
        _ = sim.StartReplay(
        [
            new ReplayEvent(1, ReplayEvent.Kind.Disconnect, Peripheral: "PROBE-A"),
            new ReplayEvent(2, ReplayEvent.Kind.State, State: "poweredOff"),
        ]);
        await clock.AdvanceAsync(TimeSpan.FromSeconds(2));
        Assert.Equal(DisconnectReason.LinkLost, await disc.NextValue());
        Assert.Equal(BluetoothState.PoweredOff, await states.NextValue());
    });

    [Fact]
    public void RecordedWritesAreAnsweredByTypeByteNotByFullFrame() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock);
        var req = Frame(0x04, crc: 0x11, payload: [1]);
        var resp1 = Frame(0x84, payload: [9, 9]);
        var resp2 = Frame(0x85);
        _ = sim.StartReplay(
        [
            new ReplayEvent(0.1, ReplayEvent.Kind.Write, Peripheral: "PROBE-A", Char: UartRx, Hex: HexString.Encode(req)),
            new ReplayEvent(0.2, ReplayEvent.Kind.Notify, Peripheral: "PROBE-A", Char: UartTx, Hex: HexString.Encode(resp1)),
            new ReplayEvent(0.3, ReplayEvent.Kind.Notify, Peripheral: "PROBE-A", Char: UartTx, Hex: HexString.Encode(resp2)),
        ]);
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
        var tx = await c.SubscribeAsync(GattUuid.UartTx);
        // Different CRC and payload, same type byte.
        await c.WriteAsync(GattUuid.UartRx, Frame(0x04, crc: 0x77, payload: [5, 6, 7]), withResponse: true);
        Assert.Equal(resp1, await tx.NextItem());
        Assert.Equal(resp2, await tx.NextItem());
        // Repeats reuse the last recording.
        await c.WriteAsync(GattUuid.UartRx, Frame(0x04), withResponse: true);
        Assert.Equal(resp1, await tx.NextItem());
        // An unknown type is unanswered.
        await c.WriteAsync(GattUuid.UartRx, Frame(0x09), withResponse: true);
        sim.InjectNotification(ProbeA, GattUuid.UartTx, [0xEE]);
        _ = await tx.NextItem(); // consume resp2 of the repeat
        Assert.Equal([0xEE], await tx.NextItem());
    });

    [Fact]
    public void RecordedResponseDelaysCanBeHonoured() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock);
        var opts = new SimulatedTransport.ReplayOptions { UseRecordedResponseDelays = true };
        _ = sim.StartReplay(
        [
            new ReplayEvent(0, ReplayEvent.Kind.Write, Peripheral: "PROBE-A", Char: UartRx, Hex: HexString.Encode(Frame(1))),
            new ReplayEvent(0.5, ReplayEvent.Kind.Notify, Peripheral: "PROBE-A", Char: UartTx, Hex: "AA"),
        ], opts);
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
        var tx = await c.SubscribeAsync(GattUuid.UartTx);
        await c.WriteAsync(GattUuid.UartRx, Frame(1), withResponse: true);
        Assert.Equal(0, tx.BufferedCount);
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(500));
        Assert.Equal([0xAA], await tx.NextItem());
    });

    private sealed class WholeFrame : IWriteMatcher
    {
        public string Key(GattUuid characteristic, ReadOnlySpan<byte> bytes) => HexString.Encode(bytes);
    }

    [Fact]
    public void MatcherCanBeSwapped() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock, matcher: new WholeFrame());
        var req = Frame(2, crc: 5);
        _ = sim.StartReplay(
        [
            new ReplayEvent(0, ReplayEvent.Kind.Write, Peripheral: "PROBE-A", Char: UartRx, Hex: HexString.Encode(req)),
            new ReplayEvent(0, ReplayEvent.Kind.Notify, Peripheral: "PROBE-A", Char: UartTx, Hex: "AB"),
        ]);
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
        var tx = await c.SubscribeAsync(GattUuid.UartTx);
        await c.WriteAsync(GattUuid.UartRx, Frame(2, crc: 6), withResponse: true); // different CRC: no match
        Assert.Equal(0, tx.BufferedCount);
        await c.WriteAsync(GattUuid.UartRx, req, withResponse: true);
        Assert.Equal([0xAB], await tx.NextItem());
    });

    [Fact]
    public void ProbeStatusNotificationsStayOnTimelineEvenAfterWrites() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock);
        _ = sim.StartReplay(
        [
            new ReplayEvent(0, ReplayEvent.Kind.Write, Peripheral: "PROBE-A", Char: UartRx, Hex: HexString.Encode(Frame(1))),
            new ReplayEvent(1, ReplayEvent.Kind.Notify, Peripheral: "PROBE-A", Char: Status, Hex: "07"),
        ]);
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
        var st = await c.SubscribeAsync(GattUuid.ProbeStatus);
        await clock.AdvanceAsync(TimeSpan.FromSeconds(1));
        Assert.Equal([7], await st.NextItem());
    });

    [Fact]
    public void RecordThenReadBackThenReplayMatchesEventSequence() => Det.Run(async () =>
    {
        var dir = TempDir();
        using var cleanup = Cleanup(dir);

        // 1. Record a scripted session.
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock);
        var request = Frame(0x01, crc: 0x22, payload: [1]);
        var response = Frame(0x81, payload: [4, 5]);
        sim.AddResponder(w => w[4] == 0x01 ? [response] : []);
        var writer = new ReplayWriter(dir, new ReplayMeta(name: "scripted", devices: [new ReplayMeta.Device("PROBE-A")]));
        var rec = new RecordingTransport(sim, writer, clock);

        var states = rec.State();
        Assert.Equal(BluetoothState.PoweredOn, await states.NextValue());
        await rec.StartScanAsync();
        var advs = rec.Advertisements();
        sim.InjectAdvertisement(ProbeA, Mfr, rssi: -61);
        Assert.Equal(-61, (await advs.NextItem())?.Rssi);
        var conn = await rec.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var tx = await conn.SubscribeAsync(GattUuid.UartTx);
        var st = await conn.SubscribeAsync(GattUuid.ProbeStatus);
        var disc = conn.Disconnected();
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(500));
        await conn.WriteAsync(GattUuid.UartRx, request, withResponse: true);
        Assert.Equal(response, await tx.NextItem());
        await clock.AdvanceAsync(TimeSpan.FromSeconds(1));
        sim.InjectNotification(ProbeA, GattUuid.ProbeStatus, [0xAA, 0xBB]);
        Assert.Equal([0xAA, 0xBB], await st.NextItem());
        sim.ForceDisconnect(ProbeA);
        Assert.Equal(DisconnectReason.LinkLost, await disc.NextValue());
        rec.Stop();

        // 2. Read back.
        var reader = new ReplayReader(dir);
        ReplayEvent[] expected =
        [
            new(0, ReplayEvent.Kind.State, State: "poweredOn"),
            new(0, ReplayEvent.Kind.Adv, Peripheral: "PROBE-A", Hex: HexString.Encode(Mfr), Rssi: -61),
            new(0, ReplayEvent.Kind.Connect, Peripheral: "PROBE-A"),
            new(0.5, ReplayEvent.Kind.Write, Peripheral: "PROBE-A", Char: UartRx, Hex: HexString.Encode(request)),
            new(0.5, ReplayEvent.Kind.Notify, Peripheral: "PROBE-A", Char: UartTx, Hex: HexString.Encode(response)),
            new(1.5, ReplayEvent.Kind.Notify, Peripheral: "PROBE-A", Char: Status, Hex: "AABB"),
            new(1.5, ReplayEvent.Kind.Disconnect, Peripheral: "PROBE-A"),
        ];
        Assert.Equal(expected, reader.Events);
        Assert.Equal("scripted", reader.Meta.Name);

        // 3. Replay into a fresh simulator and compare what the app sees.
        var clock2 = new TestClock();
        var sim2 = new SimulatedTransport(clock2);
        await sim2.StartScanAsync();
        var conn2 = await sim2.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var advs2 = sim2.Advertisements();
        var st2 = await conn2.SubscribeAsync(GattUuid.ProbeStatus);
        var tx2 = await conn2.SubscribeAsync(GattUuid.UartTx);
        var disc2 = conn2.Disconnected();
        var states2 = sim2.State();
        Assert.Equal(BluetoothState.PoweredOn, await states2.NextValue());
        _ = sim2.StartReplay(reader.Events);
        await clock2.AdvanceAsync(TimeSpan.FromMilliseconds(500));
        var adv2 = await advs2.NextItem();
        Assert.Equal(Mfr, adv2?.MfrData);
        Assert.Equal(-61, adv2?.Rssi);
        // The app repeats its request at 0.5 s and gets the recorded response.
        await conn2.WriteAsync(GattUuid.UartRx, request, withResponse: true);
        Assert.Equal(response, await tx2.NextItem());
        await clock2.AdvanceAsync(TimeSpan.FromSeconds(1));
        Assert.Equal([0xAA, 0xBB], await st2.NextItem());
        Assert.Equal(DisconnectReason.LinkLost, await disc2.NextValue());
        Assert.Equal(TimeSpan.FromMilliseconds(1500), clock2.Monotonic());
    });

    [Fact]
    public void RecordingTransportForwardsErrorsAndRecordsAppClose() => Det.Run(async () =>
    {
        var dir = TempDir();
        using var cleanup = Cleanup(dir);
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock);
        var rec = new RecordingTransport(sim, new ReplayWriter(dir), clock);
        sim.RefuseConnects(1);
        await ThrowsTransport(TransportErrorKind.ConnectionRefused, ProbeA.Raw, () => rec.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1)));
        var c = await rec.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
        await clock.AdvanceAsync(TimeSpan.FromSeconds(3));
        await c.CloseAsync();
        await c.CloseAsync(); // idempotent
        await clock.SettleAsync();
        rec.Stop();
        var events = new ReplayReader(dir).Events.Where(e => e.Type != ReplayEvent.Kind.State).ToList();
        Assert.Equal(
            [
                new ReplayEvent(0, ReplayEvent.Kind.Connect, Peripheral: "PROBE-A"),
                new ReplayEvent(3, ReplayEvent.Kind.Disconnect, Peripheral: "PROBE-A"),
            ],
            events);
    });
}
