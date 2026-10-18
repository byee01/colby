namespace Combustion.Core.Tests;

public class TestClockTests
{
    [Fact]
    public void TimeMovesOnlyOnAdvance() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var w0 = clock.Now();
        Assert.Equal(TimeSpan.Zero, clock.Monotonic());
        await clock.AdvanceAsync(TimeSpan.FromSeconds(90));
        Assert.Equal(TimeSpan.FromSeconds(90), clock.Monotonic());
        Assert.Equal(90, clock.Now().Since(w0));
    });

    [Fact]
    public void SleepersWakeInDeadlineOrder() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var log = new List<int>();
        var tasks = new[] { 3, 1, 2 }.Select(s => Spawn.Run(async () =>
        {
            await clock.SleepAsync(TimeSpan.FromSeconds(s));
            log.Add(s);
        })).ToList();
        await clock.SettleAsync();
        Assert.Equal(3, clock.SleeperCount);
        await clock.AdvanceAsync(TimeSpan.FromSeconds(5));
        await Task.WhenAll(tasks);
        Assert.Equal([1, 2, 3], log);
        Assert.Equal(0, clock.SleeperCount);
        Assert.Equal(TimeSpan.FromSeconds(5), clock.Monotonic());
    });

    [Fact]
    public void EqualDeadlinesWakeInRegistrationOrder() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var log = new List<string>();
        var tasks = new List<Task>();
        foreach (var name in new[] { "a", "b", "c" })
        {
            tasks.Add(Spawn.Run(async () =>
            {
                await clock.SleepAsync(TimeSpan.FromSeconds(1));
                log.Add(name);
            }));
        }
        await clock.AdvanceAsync(TimeSpan.FromSeconds(1));
        await Task.WhenAll(tasks);
        Assert.Equal(["a", "b", "c"], log);
    });

    [Fact]
    public void PartialAdvanceDoesNotWakeEarly() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var log = new List<string>();
        var t = Spawn.Run(async () =>
        {
            await clock.SleepAsync(TimeSpan.FromSeconds(10));
            log.Add("woke");
        });
        await clock.AdvanceAsync(TimeSpan.FromSeconds(9));
        Assert.Empty(log);
        Assert.Equal(1, clock.SleeperCount);
        await clock.AdvanceAsync(TimeSpan.FromSeconds(1));
        await t;
        Assert.Equal(["woke"], log);
    });

    [Fact]
    public void SleepLoopRunsEveryIterationWithinOneAdvance() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var log = new List<TimeSpan>();
        var t = Spawn.Run(async () =>
        {
            for (var i = 0; i < 5; i++)
            {
                await clock.SleepAsync(TimeSpan.FromSeconds(1));
                log.Add(clock.Monotonic());
            }
        });
        await clock.AdvanceAsync(TimeSpan.FromSeconds(10));
        await t;
        Assert.Equal(Enumerable.Range(1, 5).Select(i => TimeSpan.FromSeconds(i)), log);
        Assert.Equal(TimeSpan.FromSeconds(10), clock.Monotonic());
    });

    [Fact]
    public void ZeroAndNegativeSleepReturnImmediately() => Det.Run(async () =>
    {
        var clock = new TestClock();
        await clock.SleepAsync(TimeSpan.Zero);
        await clock.SleepAsync(TimeSpan.FromSeconds(-1));
        Assert.Equal(0, clock.SleeperCount);
        Assert.Equal(TimeSpan.Zero, clock.Monotonic());
    });

    [Fact]
    public void CancellingASleeperThrowsAndUnregisters() => Det.Run(async () =>
    {
        var clock = new TestClock();
        using var cts = new CancellationTokenSource();
        var t = Spawn.Run(async () =>
        {
            try
            {
                await clock.SleepAsync(TimeSpan.FromSeconds(60), cts.Token);
                return false;
            }
            catch (OperationCanceledException)
            {
                return true;
            }
        });
        await clock.SettleAsync();
        Assert.Equal(1, clock.SleeperCount);
        cts.Cancel();
        Assert.True(await t);
        Assert.Equal(0, clock.SleeperCount);
        await clock.AdvanceAsync(TimeSpan.FromSeconds(120));
    });

    [Fact]
    public void AlreadyCancelledTokenThrowsWithoutRegistering() => Det.Run(async () =>
    {
        var clock = new TestClock();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => clock.SleepAsync(TimeSpan.FromSeconds(1), new CancellationToken(true)));
        Assert.Equal(0, clock.SleeperCount);
    });

    [Fact]
    public void TimerTicksAtEachPeriod() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var ticks = clock.Timer(TimeSpan.FromSeconds(1));
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(3500));
        var seen = new List<TimeSpan>();
        for (var i = 0; i < 3; i++)
        {
            seen.Add((await ticks.NextAsync()).Value);
        }
        Assert.Equal([TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(3)], seen);
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(500));
        Assert.Equal(TimeSpan.FromSeconds(4), (await ticks.NextAsync()).Value);
    });

    [Fact]
    public void MultipleTimersInterleaveInDeadlineOrder() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var log = new List<string>();
        using var cts = new CancellationTokenSource();
        var fast = clock.Timer(TimeSpan.FromMilliseconds(300));
        var slow = clock.Timer(TimeSpan.FromMilliseconds(500));
        var a = fast.ForEachAsync(t => log.Add($"fast@{t.TotalMilliseconds}"), cts.Token);
        var b = slow.ForEachAsync(t => log.Add($"slow@{t.TotalMilliseconds}"), cts.Token);
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(1000));
        cts.Cancel();
        await Task.WhenAll(a, b);
        Assert.Equal(["fast@300", "slow@500", "fast@600", "fast@900", "slow@1000"], log);
    });

    [Fact]
    public void TimerAndSleeperShareOneTimeline() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var log = new List<string>();
        using var cts = new CancellationTokenSource();
        var tt = clock.Timer(TimeSpan.FromSeconds(2)).ForEachAsync(_ => log.Add("tick"), cts.Token);
        var st = Spawn.Run(async () =>
        {
            await clock.SleepAsync(TimeSpan.FromSeconds(3));
            log.Add("sleep");
        });
        await clock.AdvanceAsync(TimeSpan.FromSeconds(4));
        cts.Cancel();
        await st;
        await tt;
        Assert.Equal(["tick", "sleep", "tick"], log);
    });

    [Fact]
    public void TimerUnregistersWhenConsumerStops() => Det.Run(async () =>
    {
        var clock = new TestClock();
        using var cts = new CancellationTokenSource();
        var t = clock.Timer(TimeSpan.FromSeconds(1)).ForEachAsync(_ => { }, cts.Token);
        await clock.SettleAsync();
        Assert.Equal(1, clock.TimerCount);
        cts.Cancel();
        await t;
        Assert.Equal(0, clock.TimerCount);
    });

    [Fact]
    public void NonPositiveTimerPeriodFinishesImmediately() => Det.Run(async () =>
    {
        var clock = new TestClock();
        Assert.False((await clock.Timer(TimeSpan.Zero).NextAsync()).HasValue);
    });

    [Fact]
    public void SystemClockMonotonicNeverGoesBackwards()
    {
        var c = new SystemClock();
        var a = c.Monotonic();
        var b = c.Monotonic();
        Assert.True(b >= a);
    }

    [Fact]
    public void SystemClockSleepsAndTicks()
    {
        DeterministicContext.Run(async () =>
        {
            var c = new SystemClock();
            var a = c.Monotonic();
            await c.SleepAsync(TimeSpan.FromMilliseconds(20));
            Assert.True(c.Monotonic() - a >= TimeSpan.FromMilliseconds(15));
            var ticks = c.Timer(TimeSpan.FromMilliseconds(10));
            await foreach (var _ in ticks.TakeAsync(2))
            {
            }
            Assert.True(ticks.IsTerminated);
        });
    }

    [Fact]
    public void ContextReportsStall()
    {
        var e = Assert.Throws<InvalidOperationException>(() =>
            DeterministicContext.Run(() => new TestClock().SleepAsync(TimeSpan.FromSeconds(1)), TimeSpan.FromMilliseconds(50)));
        Assert.Contains("stalled", e.Message);
    }

    [Fact]
    public async Task CoreThreadRunsWorkOnOneThread()
    {
        using var core = new CoreThread();
        var ids = await core.InvokeAsync(async () =>
        {
            var before = Environment.CurrentManagedThreadId;
            await Task.Yield();
            await new SystemClock().SleepAsync(TimeSpan.FromMilliseconds(5));
            return (before, Environment.CurrentManagedThreadId);
        });
        Assert.Equal(ids.before, ids.Item2);
    }
}

public class StreamTests
{
    [Fact]
    public void BroadcasterFansOutAndReplaysLatest() => Det.Run(async () =>
    {
        var b = new Broadcaster<int>(replayLatest: true);
        var s1 = b.Stream();
        b.Send(1);
        var s2 = b.Stream();
        b.Send(2);
        b.Finish();
        Assert.Equal([1, 2], await s1.ToListAsync());
        Assert.Equal([1, 2], await s2.ToListAsync());
        Assert.Equal([2], await b.Stream().ToListAsync());
        Assert.Equal(0, b.SubscriberCount);
    });

    [Fact]
    public void ConsumerStopUnsubscribes() => Det.Run(async () =>
    {
        var b = new Broadcaster<int>();
        var s = b.Stream();
        Assert.Equal(1, b.SubscriberCount);
        b.Send(7);
        await foreach (var _ in s)
        {
            break;
        }
        Assert.Equal(0, b.SubscriberCount);
        Assert.False(s.Yield(8));
    });

    [Fact]
    public void FinishWithErrorThrowsAfterBufferedItems() => Det.Run(async () =>
    {
        var s = new AsyncStream<int>();
        var terminated = 0;
        s.OnTermination = () => terminated++;
        s.Yield(1);
        s.Finish(new TimeoutException());
        var seen = new List<int>();
        await Assert.ThrowsAsync<TimeoutException>(async () =>
        {
            await foreach (var v in s)
            {
                seen.Add(v);
            }
        });
        Assert.Equal([1], seen);
        Assert.Equal(1, terminated);
    });

    [Fact]
    public void ValueCollectionsCompareByValue()
    {
        Assert.Equal(new ValueList<int>([1, 2]), new ValueList<int>([1, 2]));
        Assert.NotEqual(new ValueList<int>([1, 2]), new ValueList<int>([2, 1]));
        Assert.Equal(new ValueSet<int>([1, 2]), new ValueSet<int>([2, 1]));
        Assert.Equal(new ValueMap<int, string>(new Dictionary<int, string> { [1] = "a" }), new ValueMap<int, string>(new Dictionary<int, string> { [1] = "a" }));
        var a = new LinkInfo([new LinkSource(LinkKind.Advertisement, TestClock.DefaultStart, Rssi: -50)]);
        var b = new LinkInfo([new LinkSource(LinkKind.Advertisement, TestClock.DefaultStart, Rssi: -50)]);
        Assert.Equal(a, b);
    }

    [Fact]
    public void GattUuidGuidRoundTrip()
    {
        Assert.Equal(new Guid("0000180A-0000-1000-8000-00805F9B34FB"), GattUuid.DeviceInformationService.ToGuid());
        Assert.Equal(GattUuid.DeviceInformationService, GattUuid.FromGuid(GattUuid.DeviceInformationService.ToGuid()));
        Assert.Equal(GattUuid.UartTx, GattUuid.FromGuid(GattUuid.UartTx.ToGuid()));
        Assert.Equal(new GattUuid("6e400003-b5a3-f393-e0a9-e50e24dcca9e"), GattUuid.UartTx);
    }
}
