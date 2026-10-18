# Porting mac/ (Swift) to windows/ (C#)

The Swift code in `mac/Sources` is the reference. Port file by file into the same folder layout under
`windows/src/<Project>/`, keep doc comments (as `///` XML), and port every Swift test with the same name in PascalCase.
A Swift test that cannot apply (Apple-only API) is listed in the test file's header comment with the reason.

## Concurrency (docs/02 §12)

- Core objects are confined to one `SynchronizationContext`: `DeterministicContext` in tests, `CoreThread` in the app.
  A Swift `actor` becomes a plain `sealed class`; state needs no locks. Interleaving happens only at `await`, exactly as
  actor reentrancy in Swift.
- Never `ConfigureAwait(false)` and never `Task.Run` in Core (continuations must come back to the core context).
  `BannedSymbols.txt` enforces this together with the clock rule.
- Only producers that run on other threads (WinRT callbacks, `Broadcaster`, `AsyncStream`) lock.
- `Task { ... }` (unstructured) becomes a private `async Task` method started with `_ = RunAsync(cts.Token)`, with a
  `CancellationTokenSource` field the owner cancels in `Stop()`/`Dispose()`. `Task.isCancelled` checks become
  `ct.IsCancellationRequested`. Catch `OperationCanceledException` at the loop top.
- `withTaskGroup`/`async let` become `Task.WhenAll`.

## Time (docs/02 §15)

- `any Clock` -> `IClock`; `Duration` -> `TimeSpan`; `Date` -> `DateTimeOffset` (UTC).
- `clock.sleep(for:)` -> `await clock.SleepAsync(d, ct)` (throws `OperationCanceledException`).
- `clock.timer(every:)` -> `clock.Timer(period)` (an `AsyncStream<TimeSpan>`).
- `a.timeIntervalSince(b)` -> `a.Since(b)` (double seconds); `addingTimeInterval(x)` -> `AddSecondsExact(x)`.
- Unix-ms columns: `Time.ToMs` / `Time.FromMs`.

## Streams

- `AsyncStream<T>` / `AsyncThrowingStream<T, Error>` -> `Combustion.Core.AsyncStream<T>` (`Yield`, `Finish(error?)`,
  `OnTermination`). Single consumer. `IAsyncEnumerable<T>` where a stream is only produced by an iterator.
- `Broadcaster<T>` is the same type. Swift `var foo: AsyncStream<T>` properties that return a new stream per access become
  methods: `Foo()`.
- `for await x in s` -> `await foreach (var x in s.WithCancellation(ct))`.

## Values

- Swift structs -> `sealed record` (or `readonly record struct` for small keys). Swift enums with payloads -> abstract
  record with nested sealed records (see `ObservationPayload`, `TraceValue`).
- Arrays / sets / dictionaries inside records -> `ValueList<T>` / `ValueSet<T>` / `ValueMap<K,V>` so `==` compares values.
  `ValueList` supports collection expressions (`[a, b]`).
- `Set<SensorIndex>` -> `SensorSet` (codec).
- Swift error enums -> one exception class with a `Kind` enum (see `TransportException`).
- Optional chaining and `guard let` map to pattern matching (`is { } x`).
- Names: `PascalCase`; async methods end in `Async`; Swift argument labels become parameter names.

## Tests

- xUnit. A test body that awaits runs on `Det.Run(async () => { ... })`.
- `TestClock.SettleAsync()` is exact on `DeterministicContext` (it returns once nothing else can run), so the Swift
  helpers `settle(clock) { condition }` and repeated `advance` loops for scheduler slack collapse to one `SettleAsync()`.
  Keep the Swift assertion; where Swift loosened an assertion for thread timing, the C# test may assert the exact value.
- `StoreFixtures`, `StoreFakeFetcher`, `Collector<T>` (`stream.Collect()`), `FirstAsync` live in
  `tests/Combustion.Core.Tests/Stores/StoreFixtures.cs`.

## Build

`dotnet test windows/Colby.sln` (warnings are errors, nullable on). The `Combustion.Transport.WinRT` and app projects
target `net8.0-windows10.0.19041.0` with `EnableWindowsTargeting=true`, so they compile on Linux; their tests run only on
Windows.
