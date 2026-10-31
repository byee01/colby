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

/// <summary><c>spec/replays</c>, found by walking up from the test binary to the repository root.</summary>
public static class Replays
{
    public static string Directory(string name)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "spec", "replays", name);
            if (System.IO.Directory.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException($"spec/replays/{name} not found above {AppContext.BaseDirectory}");
    }
}
