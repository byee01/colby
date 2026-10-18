using System.Collections.Concurrent;

namespace Combustion.Core;

/// <summary>
/// Single-threaded <see cref="SynchronizationContext"/> that runs posted continuations in order on the thread that
/// called <see cref="Run(Func{Task})"/>. Core objects are confined to one context (docs/02 §12): the app runs them on
/// one of these on a dedicated thread (<see cref="CoreThread"/>), tests run them here with a <see cref="TestClock"/>.
/// <see cref="IdleAsync"/> completes once nothing else is ready to run, which makes <see cref="TestClock"/> settle exactly.
/// </summary>
public sealed class DeterministicContext : SynchronizationContext
{
    private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> _queue = new();
    private readonly Queue<TaskCompletionSource> _idleWaiters = new();
    private readonly int _threadId = Environment.CurrentManagedThreadId;

    /// <summary>How long <see cref="Run(Func{Task})"/> waits for work from another thread (real I/O) before it reports a
    /// deadlock. Infinite on <see cref="CoreThread"/>.</summary>
    public TimeSpan StallTimeout { get; init; } = TimeSpan.FromSeconds(10);

    public static new DeterministicContext? Current => SynchronizationContext.Current as DeterministicContext;

    public override void Post(SendOrPostCallback d, object? state) => _queue.Add((d, state));

    public override void Send(SendOrPostCallback d, object? state)
    {
        if (Environment.CurrentManagedThreadId == _threadId)
        {
            d(state);
            return;
        }
        using var done = new ManualResetEventSlim();
        Post(_ => { d(state); done.Set(); }, null);
        done.Wait();
    }

    public override SynchronizationContext CreateCopy() => this;

    /// <summary>Completes after every continuation queued before and because of this call has run.</summary>
    public Task IdleAsync()
    {
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _idleWaiters.Enqueue(tcs);
        return tcs.Task;
    }

    /// <summary>Runs <paramref name="body"/> on a new context on this thread until it completes.</summary>
    public static void Run(Func<Task> body, TimeSpan? stallTimeout = null)
    {
        var context = new DeterministicContext { StallTimeout = stallTimeout ?? TimeSpan.FromSeconds(10) };
        context.RunLoop(body);
    }

    public static T Run<T>(Func<Task<T>> body)
    {
        T result = default!;
        Run(async () => result = await body());
        return result;
    }

    internal void RunLoop(Func<Task> body)
    {
        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(this);
        try
        {
            var task = body();
            task.ContinueWith(_ => _queue.Add((_ => { }, null)), TaskScheduler.Default);
            while (!task.IsCompleted)
            {
                if (_queue.TryTake(out var item))
                {
                    item.Callback(item.State);
                    continue;
                }
                if (_idleWaiters.Count > 0)
                {
                    // Release one waiter at a time so two settlers interleave in order.
                    _idleWaiters.Dequeue().TrySetResult();
                    continue;
                }
                var timeout = StallTimeout == Timeout.InfiniteTimeSpan ? -1 : (int)StallTimeout.TotalMilliseconds;
                if (!_queue.TryTake(out item, timeout))
                {
                    throw new InvalidOperationException(
                        $"DeterministicContext stalled: nothing ran for {StallTimeout} and the body is still waiting (deadlock, or a TestClock that needs advancing).");
                }
                item.Callback(item.State);
            }
            task.GetAwaiter().GetResult();
        }
        finally
        {
            SynchronizationContext.SetSynchronizationContext(previous);
        }
    }
}

/// <summary>A dedicated thread running a <see cref="DeterministicContext"/>; the app's home for Core objects.</summary>
public sealed class CoreThread : IDisposable
{
    private readonly Thread _thread;
    private readonly TaskCompletionSource<DeterministicContext> _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _stop = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public CoreThread(string name = "Combustion.Core")
    {
        _thread = new Thread(() =>
        {
            var context = new DeterministicContext { StallTimeout = Timeout.InfiniteTimeSpan };
            context.RunLoop(async () =>
            {
                _ready.SetResult(context);
                await _stop.Task;
            });
        })
        { IsBackground = true, Name = name };
        _thread.Start();
    }

    public SynchronizationContext Context => _ready.Task.GetAwaiter().GetResult();

    /// <summary>Runs <paramref name="work"/> on the core thread and returns its result.</summary>
    public Task<T> InvokeAsync<T>(Func<Task<T>> work)
    {
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Context.Post(async _ =>
        {
            try
            {
                tcs.SetResult(await work());
            }
            catch (Exception e)
            {
                tcs.SetException(e);
            }
        }, null);
        return tcs.Task;
    }

    public Task InvokeAsync(Func<Task> work) => InvokeAsync(async () =>
    {
        await work();
        return true;
    });

    public void Dispose()
    {
        _stop.TrySetResult();
        _thread.Join();
    }
}
