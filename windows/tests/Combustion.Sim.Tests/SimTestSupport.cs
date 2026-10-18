namespace Combustion.Sim.Tests;

/// <summary>Runs a test body on a <see cref="DeterministicContext"/> so <see cref="TestClock"/> settles exactly.</summary>
public static class Det
{
    public static void Run(Func<Task> body) => DeterministicContext.Run(body);
}

/// <summary>Starts a task on the current context without awaiting it (Swift <c>Task { }</c>).</summary>
public static class Spawn
{
    public static Task Run(Func<Task> body) => body();

    public static Task<T> Run<T>(Func<Task<T>> body) => body();
}

public static class Sim
{
    public static string TempDir() => Path.Combine(Path.GetTempPath(), $"colby-sim-{Guid.NewGuid()}");

    /// <summary>Removes a temp directory at the end of a test (Swift <c>defer { removeItem }</c>).</summary>
    public static IDisposable Cleanup(string dir) => new DirectoryCleanup(dir);

    /// <summary>Probe-style UART frame: sync(2) crc(2) type(1) len(1) payload. The CRC is not validated by the
    /// simulator, so a filler is used.</summary>
    public static byte[] Frame(byte type, byte crc = 0, byte[]? payload = null)
    {
        payload ??= [];
        return [0xCA, 0xFE, crc, crc, type, (byte)payload.Length, .. payload];
    }

    public static readonly PeripheralId ProbeA = "PROBE-A";

    public static readonly byte[] Mfr = [0xC7, 0x09, 0x01, 0x3F, 0x5A, 0x00, 0x10];

    /// <summary>Asserts the task throws a <see cref="TransportException"/> of <paramref name="kind"/> (and detail).</summary>
    public static async Task ThrowsTransport(TransportErrorKind kind, string? detail, Func<Task> body)
    {
        var e = await Assert.ThrowsAsync<TransportException>(body);
        Assert.Equal(kind, e.Kind);
        if (detail is not null)
        {
            Assert.Equal(detail, e.Detail);
        }
    }

    private sealed class DirectoryCleanup(string dir) : IDisposable
    {
        public void Dispose()
        {
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }
}

public static class StreamTestExtensions
{
    /// <summary>Swift <c>await iterator.next()</c> for value elements: null once the stream ends.</summary>
    public static async Task<T?> NextValue<T>(this AsyncStream<T> stream) where T : struct
    {
        var (has, value) = await stream.NextAsync();
        return has ? value : null;
    }

    /// <summary>Swift <c>await iterator.next()</c> for reference elements: null once the stream ends.</summary>
    public static async Task<T?> NextItem<T>(this AsyncStream<T> stream) where T : class
    {
        var (has, value) = await stream.NextAsync();
        return has ? value : null;
    }
}

/// <summary>Collects a stream's elements on the current context until disposed (Swift: a Task appending to a log).</summary>
public sealed class Collector<T> : IDisposable
{
    private readonly CancellationTokenSource _cts = new();

    public Collector(IAsyncEnumerable<T> source)
    {
        Done = source.ForEachAsync(Items.Add, _cts.Token);
    }

    public List<T> Items { get; } = [];

    public Task Done { get; }

    public int Count => Items.Count;

    public T? Last => Items.Count > 0 ? Items[^1] : default;

    public void Dispose() => _cts.Cancel();
}
