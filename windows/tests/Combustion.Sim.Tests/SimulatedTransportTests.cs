using System.Text;
using static Combustion.Sim.Tests.Sim;

namespace Combustion.Sim.Tests;

public class SimulatedTransportTests
{
    private static (TestClock Clock, SimulatedTransport Sim) Make()
    {
        var clock = new TestClock();
        return (clock, new SimulatedTransport(clock));
    }

    [Fact]
    public void StateStreamStartsWithCurrentAndFollowsChanges() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        var it = sim.State();
        Assert.Equal(BluetoothState.PoweredOn, await it.NextValue());
        sim.SetState(BluetoothState.PoweredOff);
        Assert.Equal(BluetoothState.PoweredOff, await it.NextValue());
        var late = sim.State();
        Assert.Equal(BluetoothState.PoweredOff, await late.NextValue());
    });

    [Fact]
    public void AdvertisementsOnlyWhileScanning() => Det.Run(async () =>
    {
        var (clock, sim) = Make();
        var it = sim.Advertisements();
        sim.InjectAdvertisement(ProbeA, [1]); // not scanning: dropped
        await sim.StartScanAsync();
        await clock.AdvanceAsync(TimeSpan.FromSeconds(2));
        sim.InjectAdvertisement(ProbeA, Mfr, rssi: -70);
        var adv = await it.NextItem();
        Assert.Equal(Mfr, adv?.MfrData);
        Assert.Equal(-70, adv?.Rssi);
        Assert.Equal(clock.Now(), adv?.Time);
        await sim.StopScanAsync();
        sim.InjectAdvertisement(ProbeA, [2]);
        sim.SetState(BluetoothState.PoweredOff); // finishes nothing, but proves the stream has no stray element
        Assert.Empty(sim.Writes);
        // Exact on one thread: nothing else was delivered.
        Assert.Equal(0, it.BufferedCount);
    });

    [Fact]
    public void ConnectDiscoverReadAndMTU() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        sim.SetMtu(247);
        sim.SetReadValue(Encoding.UTF8.GetBytes("1.2.3"), GattUuid.FirmwareRevision, ProbeA);
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        Assert.Equal(247, c.Mtu);
        Assert.Equal(ProbeA, c.Peripheral);
        var services = await c.DiscoverAsync();
        Assert.Contains(GattUuid.UartService, services.Select(s => s.Uuid));
        Assert.Equal(Encoding.UTF8.GetBytes("1.2.3"), await c.ReadAsync(GattUuid.FirmwareRevision));
        await ThrowsTransport(TransportErrorKind.CharacteristicNotFound, GattUuid.ModelNumber.Raw, () => c.ReadAsync(GattUuid.ModelNumber));
    });

    [Fact]
    public void SecondConnectionToSamePeripheralIsRejected() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        await ThrowsTransport(TransportErrorKind.AlreadyConnected, ProbeA.Raw, () => sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5)));
        await c.CloseAsync();
        _ = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
    });

    [Fact]
    public void InjectedNotificationReachesOnlySubscribers() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var status = await c.SubscribeAsync(GattUuid.ProbeStatus);
        sim.InjectNotification(ProbeA, GattUuid.UartTx, [9]); // nobody subscribed
        sim.InjectNotification("other", GattUuid.ProbeStatus, [8]);
        sim.InjectNotification(ProbeA, GattUuid.ProbeStatus, [1, 2]);
        Assert.Equal([1, 2], await status.NextItem());
    });

    [Fact]
    public void ResponderAnswersWritesOnReplyCharacteristic() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        sim.AddResponder(write => [Frame((byte)(write[4] | 0x80)), Frame(0x7F)]);
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var tx = await c.SubscribeAsync(GattUuid.UartTx);
        await c.WriteAsync(GattUuid.UartRx, Frame(0x04), withResponse: true);
        Assert.Equal(Frame(0x84), await tx.NextItem());
        Assert.Equal(Frame(0x7F), await tx.NextItem());
        Assert.Equal([new SimulatedWrite(ProbeA, GattUuid.UartRx, Frame(0x04))], sim.Writes);
    });

    [Fact]
    public void DropAndDuplicateFaults() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var it = await c.SubscribeAsync(GattUuid.ProbeStatus);
        sim.DropNextNotifications(1);
        sim.InjectNotification(ProbeA, GattUuid.ProbeStatus, [1]);
        sim.DuplicateNextNotifications(1, on: GattUuid.ProbeStatus);
        sim.InjectNotification(ProbeA, GattUuid.ProbeStatus, [2]);
        sim.InjectNotification(ProbeA, GattUuid.ProbeStatus, [3]);
        Assert.Equal([2], await it.NextItem());
        Assert.Equal([2], await it.NextItem());
        Assert.Equal([3], await it.NextItem());
    });

    [Fact]
    public void FaultOnOtherCharacteristicIsNotConsumed() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var it = await c.SubscribeAsync(GattUuid.ProbeStatus);
        sim.DropNextNotifications(1, on: GattUuid.UartTx);
        sim.InjectNotification(ProbeA, GattUuid.ProbeStatus, [1]);
        Assert.Equal([1], await it.NextItem());
    });

    [Fact]
    public void DelayedResponsesArriveOnlyAfterClockAdvances() => Det.Run(async () =>
    {
        var (clock, sim) = Make();
        sim.AddResponder(_ => [[0xAA]]);
        sim.SetResponseDelay(TimeSpan.FromMilliseconds(300));
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var tx = await c.SubscribeAsync(GattUuid.UartTx);
        await c.WriteAsync(GattUuid.UartRx, Frame(1), withResponse: true);
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(299));
        sim.InjectNotification(ProbeA, GattUuid.UartTx, [0x01]); // marker
        Assert.Equal([0x01], await tx.NextItem());
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(1));
        Assert.Equal([0xAA], await tx.NextItem());
    });

    [Fact]
    public void RefuseConnectThenAllow() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        sim.RefuseConnects(2);
        await ThrowsTransport(TransportErrorKind.ConnectionRefused, ProbeA.Raw, () => sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1)));
        await ThrowsTransport(TransportErrorKind.ConnectionRefused, ProbeA.Raw, () => sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1)));
        _ = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
        sim.ForceDisconnect(ProbeA);
        sim.RefuseConnects(1, error: TransportException.OperationFailed("slots full"));
        await ThrowsTransport(TransportErrorKind.OperationFailed, "slots full", () => sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1)));
    });

    [Fact]
    public void ConnectDelayLongerThanTimeoutThrowsTimeout() => Det.Run(async () =>
    {
        var (clock, sim) = Make();
        sim.SetConnectDelay(TimeSpan.FromSeconds(10));
        var attempt = Spawn.Run(async () =>
        {
            try
            {
                _ = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(4));
                return (TransportException?)null;
            }
            catch (TransportException e)
            {
                return e;
            }
        });
        await clock.AdvanceAsync(TimeSpan.FromSeconds(4));
        Assert.Equal(TransportErrorKind.Timeout, (await attempt)?.Kind);

        sim.SetConnectDelay(TimeSpan.FromSeconds(2));
        var ok = Spawn.Run(() => sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(4)));
        await clock.AdvanceAsync(TimeSpan.FromSeconds(2));
        _ = await ok;
    });

    [Fact]
    public void ForceDisconnectEndsStreamsAndFailsFurtherIO() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var sub = await c.SubscribeAsync(GattUuid.ProbeStatus);
        var disc = c.Disconnected();
        sim.ForceDisconnect(ProbeA, DisconnectReason.Timeout);
        Assert.Equal(DisconnectReason.Timeout, await disc.NextValue());
        Assert.Null(await disc.NextValue());
        Assert.Null(await sub.NextItem());
        await ThrowsTransport(TransportErrorKind.Disconnected, null, () => c.WriteAsync(GattUuid.UartRx, [1], withResponse: false));
        // Late observers still learn the reason.
        var late = c.Disconnected();
        Assert.Equal(DisconnectReason.Timeout, await late.NextValue());
    });

    [Fact]
    public void CloseReportsRequested() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var disc = c.Disconnected();
        await c.CloseAsync();
        Assert.Equal(DisconnectReason.Requested, await disc.NextValue());
    });

    [Fact]
    public void BluetoothOffDropsConnectionsAndBlocksConnect() => Det.Run(async () =>
    {
        var (_, sim) = Make();
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(5));
        var disc = c.Disconnected();
        sim.SetState(BluetoothState.PoweredOff);
        Assert.Equal(DisconnectReason.BluetoothOff, await disc.NextValue());
        await ThrowsTransport(TransportErrorKind.NotPoweredOn, nameof(BluetoothState.PoweredOff), () => sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1)));
        sim.SetState(BluetoothState.PoweredOn);
        _ = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
    });
}

public class SimulatedTransportConnectAndFaultTests
{
    [Fact]
    public void BlockedConnectsAreRefusedUntilAllowed() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock);
        sim.BlockConnects(ProbeA);
        await ThrowsTransport(TransportErrorKind.ConnectionRefused, ProbeA.Raw, () => sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1)));
        Assert.False(sim.IsConnected(ProbeA));
        sim.AllowConnects(ProbeA);
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
        Assert.True(sim.IsConnected(ProbeA));
        await c.CloseAsync();
        Assert.False(sim.IsConnected(ProbeA));
    });

    [Fact]
    public void DropCanSkipNotificationsFirst() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var sim = new SimulatedTransport(clock);
        var c = await sim.ConnectAsync(ProbeA, TimeSpan.FromSeconds(1));
        var it = await c.SubscribeAsync(GattUuid.UartTx);
        sim.DropNextNotifications(2, after: 3, on: GattUuid.UartTx);
        for (var i = 0; i < 8; i++)
        {
            sim.InjectNotification(ProbeA, GattUuid.UartTx, [(byte)i]);
        }
        var got = new List<byte>();
        for (var i = 0; i < 6; i++)
        {
            if (await it.NextItem() is { } b)
            {
                got.AddRange(b);
            }
        }
        Assert.Equal([0, 1, 2, 5, 6, 7], got);
        Assert.Equal(0, it.BufferedCount);
    });
}
