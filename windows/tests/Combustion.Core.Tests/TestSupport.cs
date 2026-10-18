namespace Combustion.Core.Tests;

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
