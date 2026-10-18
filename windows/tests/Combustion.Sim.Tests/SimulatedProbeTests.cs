using static Combustion.Sim.Tests.Sim;

namespace Combustion.Sim.Tests;

public class SimulatedProbeTests
{
    private static readonly ProbeSerial Serial = new(0x1000_5A3F);

    private sealed class Rig
    {
        public Rig(uint sessionId = 9, int preload = 0)
        {
            Transport = new SimulatedTransport(Clock);
            Probe = new SimulatedProbe(Serial, Transport, Clock, sessionId: sessionId);
            if (preload > 0)
            {
                Probe.Preload(preload);
            }
        }

        public TestClock Clock { get; } = new();

        public SimulatedTransport Transport { get; }

        public SimulatedProbe Probe { get; }

        /// <summary>Swift advanced in 250 ms steps and yielded after each for scheduler slack; one
        /// <see cref="TestClock.AdvanceAsync(TimeSpan)"/> fires every tick and settles exactly.</summary>
        public Task Advance(TimeSpan d) => Clock.AdvanceAsync(d);

        public Task Request(UartRequest r, IGattConnection connection) =>
            connection.WriteAsync(GattUuid.UartRx, CombustionCodec.EncodeRequest(UartVariant.Probe, r), withResponse: true);
    }

    /// <summary>Collects frames from a stream until <paramref name="count"/> arrive.</summary>
    private static async Task<List<UartResponse>> Frames(AsyncStream<byte[]> stream, int count)
    {
        var framer = new UartFramer(UartVariant.Probe, UartDirection.Response);
        var output = new List<UartResponse>();
        await foreach (var bytes in stream)
        {
            foreach (var item in framer.Push(bytes))
            {
                if (item is UartFramerOutput.FrameOutput { Frame: var f })
                {
                    try
                    {
                        output.Add(CombustionCodec.DecodeResponse(f));
                    }
                    catch (CodecException)
                    {
                    }
                }
            }
            if (output.Count >= count)
            {
                break;
            }
        }
        return output;
    }

    private static Task<T?> First<T>(AsyncStream<T> stream) where T : class =>
        Spawn.Run(async () =>
        {
            await foreach (var a in stream)
            {
                return a;
            }
            return (T?)null;
        });

    [Fact]
    public void AdvertisesEveryQuarterSecondOnlyWhileInRange() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.Start();
        await rig.Transport.StartScanAsync();
        using var seen = rig.Transport.Advertisements().Collect();
        await rig.Advance(TimeSpan.FromSeconds(2));
        var inRange = seen.Count;
        Assert.Equal(8, inRange);

        rig.Probe.SetInRange(false);
        await rig.Advance(TimeSpan.FromSeconds(2));
        Assert.Equal(inRange, seen.Count);
        rig.Probe.SetInRange(true);
        await rig.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(inRange + 4, seen.Count);
    });

    [Fact]
    public void AdvertisementCarriesSerialAndEightTemperatures() => Det.Run(async () =>
    {
        var rig = new Rig(preload: 200);
        rig.Probe.Start();
        await rig.Transport.StartScanAsync();
        var first = First(rig.Transport.Advertisements());
        await rig.Advance(TimeSpan.FromMilliseconds(250));
        var raw = Assert.IsType<RawAdvertisement>(await first);
        var packet = Assert.IsType<AdvertisementPacket.Probe>(CombustionCodec.DecodeAdvertisement(raw.MfrData));
        var ad = packet.Advertisement;
        Assert.Equal(Serial, ad.Serial);
        Assert.Equal(rig.Probe.Record(200)!.Value.Temperatures.Celsius, ad.Temperatures.Celsius);
        // The default cook curve spreads the sensors: T8 (ambient) leads T1 (core).
        Assert.True(ad.Temperatures[SensorIndex.T8] > ad.Temperatures[SensorIndex.T1]);
    });

    [Fact]
    public void LogsOneRecordPerSamplePeriodAndSendsStatusOnlyWhenConnected() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.Start();
        await rig.Transport.StartScanAsync();
        await rig.Advance(TimeSpan.FromSeconds(10));
        Assert.Equal(new LogRange(0, 2), rig.Probe.LogRange);

        var connection = await rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1));
        var status = await connection.SubscribeAsync(GattUuid.ProbeStatus);
        var task = First(status);
        await rig.Advance(TimeSpan.FromSeconds(5));
        var payload = CombustionCodec.DecodeProbeStatus(Assert.IsType<byte[]>(await task));
        Assert.Equal(new LogRange(0, 3), payload.LogRange);
        Assert.Equal(new SessionInfo(9, 5000), payload.Session);
        Assert.Equal(rig.Probe.Record(3)!.Value.Temperatures, payload.Temperatures);
    });

    [Fact]
    public void AnswersSessionInfoAndLogRequests() => Det.Run(async () =>
    {
        var rig = new Rig(preload: 20);
        rig.Probe.Start();
        var connection = await rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1));
        var tx = await connection.SubscribeAsync(GattUuid.UartTx);

        await rig.Request(new UartRequest.ReadSessionInfo(), connection);
        await rig.Request(new UartRequest.ReadLogs(5, 8), connection);
        var responses = await Frames(tx, 5);
        Assert.Equal(new ResponseBody.SessionInfoBody(null, new SessionInfo(9, 5000)), responses.FirstOrDefault().Body);
        var records = responses.Skip(1).Select(r => r.Body).OfType<ResponseBody.LogRecordBody>().Select(b => b.Record).ToList();
        Assert.Equal([5u, 6u, 7u, 8u], records.Select(r => r.Sequence));
        Assert.Equal(Enumerable.Range(5, 4).Select(s => rig.Probe.Record((uint)s)!.Value.Temperatures), records.Select(r => r.Temperatures));
        Assert.Equal([new UartRequest.ReadSessionInfo(), new UartRequest.ReadLogs(5, 8)], rig.Probe.Requests);
    });

    [Fact]
    public void ReadLogsBeyondTheEndIsClampedAndPastTheEndIsSilent() => Det.Run(async () =>
    {
        var rig = new Rig(preload: 4); // seqs 0...4
        rig.Probe.Start();
        var connection = await rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1));
        var tx = await connection.SubscribeAsync(GattUuid.UartTx);
        await rig.Request(new UartRequest.ReadLogs(3, 100), connection);
        await rig.Request(new UartRequest.ReadLogs(50, 60), connection);
        await rig.Request(new UartRequest.SilenceAlarms(), connection);
        var responses = await Frames(tx, 3);
        Assert.Equal([4, 4, UartMessageType.SilenceAlarms], responses.Select(r => r.MessageType));
    });

    [Fact]
    public void CommandsAreAcknowledgedAndRemembered() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.Start();
        var connection = await rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1));
        var tx = await connection.SubscribeAsync(GattUuid.UartTx);
        var alarms = new AlarmConfig(high: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.Core] = new(true, 70) });
        await rig.Request(new UartRequest.SetPrediction(63, PredictionMode.TimeToRemoval), connection);
        await rig.Request(new UartRequest.SetAlarms(alarms), connection);
        await rig.Request(new UartRequest.SilenceAlarms(), connection);
        var responses = await Frames(tx, 3);
        Assert.Equal([UartMessageType.SetPrediction, UartMessageType.SetAlarms, UartMessageType.SilenceAlarms], responses.Select(r => r.MessageType));
        Assert.All(responses, r =>
        {
            Assert.True(r.Success);
            Assert.Equal(new ResponseBody.Ack(), r.Body);
        });
        Assert.Equal(63, rig.Probe.CurrentPrediction.Setpoint);
        Assert.Equal(PredictionMode.TimeToRemoval, rig.Probe.CurrentPrediction.Mode);
        Assert.Equal(70, rig.Probe.CurrentAlarms.High[AlarmChannel.Core].Temperature);
    });

    // MARK: Prediction, alarms, silence

    /// <summary>Statuses the app would receive, decoded, newest last.</summary>
    private static async Task<(IGattConnection Connection, List<ProbeStatusPayload> Statuses)> Listen(Rig rig)
    {
        var connection = await rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1));
        var stream = await connection.SubscribeAsync(GattUuid.ProbeStatus);
        var log = new List<ProbeStatusPayload>();
        _ = stream.ForEachAsync(b =>
        {
            try
            {
                log.Add(CombustionCodec.DecodeProbeStatus(b));
            }
            catch (CodecException)
            {
            }
        });
        return (connection, log);
    }

    [Fact]
    public void SetPredictionStartsACountdownAndStatusShowsItAtOnce() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.PredictionLeadSeconds = 100;
        rig.Probe.Start();
        var (connection, statuses) = await Listen(rig);
        await rig.Advance(TimeSpan.FromSeconds(5));
        var before = statuses.Count;
        Assert.Equal(PredictionState.NotInserted, statuses[^1].Prediction.State);

        await rig.Request(new UartRequest.SetPrediction(63, PredictionMode.TimeToRemoval), connection);
        await rig.Clock.SettleAsync();
        // A status right after the command, not at the next sample.
        Assert.Equal(before + 1, statuses.Count);
        var now = statuses[before];
        Assert.Equal(PredictionState.Predicting, now.Prediction.State);
        Assert.True(now.Prediction.Mode == PredictionMode.TimeToRemoval && now.Prediction.Type == PredictionType.Removal);
        Assert.Equal(63, now.Prediction.Setpoint);
        Assert.Equal(100u, now.Prediction.RawSecondsRemaining);

        await rig.Advance(TimeSpan.FromSeconds(30));
        var later = statuses[^1];
        Assert.Equal(70u, later.Prediction.RawSecondsRemaining);
        Assert.True(later.Prediction.EstimatedCore > now.Prediction.EstimatedCore, "the estimate climbs toward the set point");
        // The log records carry the same prediction.
        var record = Assert.IsType<LogRecord>(rig.Probe.Record(later.LogRange.Max));
        Assert.True(record.Prediction.State == PredictionState.Predicting && record.Prediction.RawSecondsRemaining == 70);
    });

    [Fact]
    public void PredictionEndsDoneAndRemovalAndRestingContinuesIntoResting() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.PredictionLeadSeconds = 20;
        rig.Probe.RestingSeconds = 15;
        rig.Probe.Start();
        var (connection, statuses) = await Listen(rig);
        await rig.Request(new UartRequest.SetPrediction(60, PredictionMode.RemovalAndResting), connection);
        await rig.Advance(TimeSpan.FromSeconds(60));
        var phases = statuses.Select(s => $"{s.Prediction.State}/{s.Prediction.Type}");
        var collapsed = new List<string>();
        foreach (var p in phases)
        {
            if (collapsed.Count == 0 || collapsed[^1] != p)
            {
                collapsed.Add(p);
            }
        }
        Assert.Equal(
            ["Predicting/Removal", "RemovalPredictionDone/Removal", "Predicting/Resting", "RemovalPredictionDone/Resting"],
            collapsed.TakeLast(4));
    });

    [Fact]
    public void CancellingThePredictionResetsIt() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.Start();
        var (connection, statuses) = await Listen(rig);
        await rig.Request(new UartRequest.SetPrediction(60, PredictionMode.TimeToRemoval), connection);
        await rig.Request(new UartRequest.SetPrediction(0, PredictionMode.None), connection);
        await rig.Clock.SettleAsync();
        Assert.Equal(PredictionState.NotInserted, statuses[^1].Prediction.State);
        Assert.Equal(PredictionMode.None, statuses[^1].Prediction.Mode);
    });

    [Fact]
    public void AlarmTripsWhenTheTemperatureIsReachedAndSilenceQuietsItButKeepsItTripped() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.SetCurve((seq, _) => Enumerable.Repeat(20.0 + seq, 8).ToArray()); // +1 °C per sample
        rig.Probe.Start();
        var (connection, statuses) = await Listen(rig);
        var config = new AlarmConfig(
            high: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.Core] = new(true, 24), [AlarmChannel.Ambient] = new(true, 90) },
            low: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.Surface] = new(true, 21) });
        await rig.Request(new UartRequest.SetAlarms(config), connection);
        await rig.Clock.SettleAsync();
        // Set while the probe reads 20 °C: the low surface alarm (21) is not reached and the high ones are not either.
        Assert.False(statuses[^1].Alarms?.High[AlarmChannel.Core].Alarming);
        Assert.True(statuses[^1].Alarms?.High[AlarmChannel.Core].IsSet);

        await rig.Advance(TimeSpan.FromSeconds(25)); // the record reaches 24 and beyond
        var tripped = Assert.IsType<AlarmConfig>(statuses[^1].Alarms);
        Assert.True(tripped.High[AlarmChannel.Core].Tripped && tripped.High[AlarmChannel.Core].Alarming);
        Assert.False(tripped.High[AlarmChannel.Ambient].Tripped, "90 °C is not reached");

        await rig.Request(new UartRequest.SilenceAlarms(), connection);
        await rig.Clock.SettleAsync();
        var quiet = Assert.IsType<AlarmConfig>(statuses[^1].Alarms);
        Assert.True(!quiet.High[AlarmChannel.Core].Alarming && quiet.High[AlarmChannel.Core].Tripped);
        await rig.Advance(TimeSpan.FromSeconds(15));
        Assert.False(statuses[^1].Alarms?.High[AlarmChannel.Core].Alarming, "silenced stays silenced");
    });

    [Fact]
    public void AlarmsAlreadyBeyondTheirTemperatureTripAtOnce() => Det.Run(async () =>
    {
        var rig = new Rig(preload: 10);
        rig.Probe.SetCurve((_, _) => Enumerable.Repeat(50.0, 8).ToArray());
        rig.Probe.Preload(1); // a record made with the new curve
        rig.Probe.Start();
        var (connection, statuses) = await Listen(rig);
        await rig.Request(new UartRequest.SetAlarms(new AlarmConfig(low: new Dictionary<AlarmChannel, Alarm> { [AlarmChannel.Core] = new(true, 60) })), connection);
        await rig.Clock.SettleAsync();
        Assert.True(statuses[^1].Alarms?.Low[AlarmChannel.Core].Alarming);
        // Read-only bits sent by the app are ignored.
        await rig.Request(new UartRequest.SetAlarms(new AlarmConfig(low: new Dictionary<AlarmChannel, Alarm>
        {
            [AlarmChannel.Core] = new(false, 60, Tripped: true, Alarming: true),
        })), connection);
        await rig.Clock.SettleAsync();
        Assert.False(statuses[^1].Alarms?.Low[AlarmChannel.Core].Alarming);
    });

    [Fact]
    public void BatteryAndOverheatAreReportedInAdvertisementAndStatus() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.BatteryLow = true;
        rig.Probe.Overheating = SensorSet.Of(SensorIndex.T2);
        rig.Probe.Start();
        await rig.Transport.StartScanAsync();
        var first = First(rig.Transport.Advertisements());
        var (_, statuses) = await Listen(rig);
        await rig.Advance(TimeSpan.FromSeconds(5));
        var raw = Assert.IsType<RawAdvertisement>(await first);
        var ad = Assert.IsType<AdvertisementPacket.Probe>(CombustionCodec.DecodeAdvertisement(raw.MfrData)).Advertisement;
        Assert.True(ad.BatteryLow && ad.Overheating == SensorSet.Of(SensorIndex.T2));
        Assert.True(statuses[^1].BatteryLow && statuses[^1].Overheating == SensorSet.Of(SensorIndex.T2));
    });

    [Fact]
    public void OutOfRangeDropsTheLinkAndRefusesConnects() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.Start();
        var connection = await rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1));
        var drops = connection.Disconnected();
        rig.Probe.SetInRange(false);
        Assert.Equal(DisconnectReason.LinkLost, await drops.NextValue());
        await ThrowsTransport(TransportErrorKind.ConnectionRefused, rig.Probe.Peripheral.Raw,
            () => rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1)));
        rig.Probe.SetInRange(true);
        _ = await rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1));
    });

    [Fact]
    public void NewSessionRestartsTheLogWithANewId() => Det.Run(async () =>
    {
        var rig = new Rig(sessionId: 5, preload: 50);
        rig.Probe.Start();
        Assert.Equal(50u, rig.Probe.LogRange.Max);
        rig.Probe.NewSession();
        Assert.Equal(6u, rig.Probe.SessionId);
        Assert.Equal(new LogRange(0, 0), rig.Probe.LogRange);
        await rig.Advance(TimeSpan.FromSeconds(10));
        Assert.Equal(2u, rig.Probe.LogRange.Max);
        rig.Probe.NewSession(sessionId: 1000);
        Assert.Equal(1000u, rig.Probe.SessionId);
    });

    [Fact]
    public void LegacyFirmwareHasNoSessionIdAndRejectsSessionInfo() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.LegacyFirmware = true;
        rig.Probe.Start();
        var connection = await rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1));
        var status = await connection.SubscribeAsync(GattUuid.ProbeStatus);
        var tx = await connection.SubscribeAsync(GattUuid.UartTx);
        var bytes = First(status);
        await rig.Advance(TimeSpan.FromSeconds(5));
        var raw = Assert.IsType<byte[]>(await bytes);
        Assert.Equal(94, raw.Length);
        Assert.Null(CombustionCodec.DecodeProbeStatus(raw).Session);

        await rig.Request(new UartRequest.ReadSessionInfo(), connection);
        var r = Assert.Single(await Frames(tx, 1));
        Assert.False(r.Success);
    });

    [Fact]
    public void LinkDropsAfterAPartialLogDownload() => Det.Run(async () =>
    {
        var rig = new Rig(preload: 99);
        rig.Probe.Start();
        var connection = await rig.Transport.ConnectAsync(rig.Probe.Peripheral, TimeSpan.FromSeconds(1));
        var tx = await connection.SubscribeAsync(GattUuid.UartTx);
        var drops = connection.Disconnected();
        rig.Probe.DropLinkAfterLogRecords(10);
        await rig.Request(new UartRequest.ReadLogs(0, 99), connection);
        Assert.Equal(10, (await Frames(tx, 10)).Count);
        await rig.Advance(TimeSpan.FromMilliseconds(250));
        Assert.Equal(DisconnectReason.LinkLost, await drops.NextValue());
    });

    [Fact]
    public void CustomCurveShapesTheRecords() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Probe.SetCurve((seq, _) => Enumerable.Repeat(30.0 + seq, 8).ToArray());
        rig.Probe.Start();
        await rig.Advance(TimeSpan.FromSeconds(10));
        Assert.Equal(32, rig.Probe.Record(2)!.Value.Temperatures[SensorIndex.T3]);
    });
}

internal static class CollectExtensions
{
    public static Collector<T> Collect<T>(this IAsyncEnumerable<T> source) => new(source);
}
