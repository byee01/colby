using System.Text.Json;
using System.Text.Json.Nodes;

namespace Combustion.Codec.Tests;

/// <summary>Fixture hex helpers (uppercase, no separators).</summary>
internal static class Hex
{
    /// <summary>Parses hex, ignoring any character that is not a hex digit.</summary>
    public static byte[] Bytes(string? text)
    {
        var output = new List<byte>();
        int? high = null;
        foreach (var c in text ?? "")
        {
            if (!Uri.IsHexDigit(c))
            {
                continue;
            }
            var nibble = Convert.ToInt32(c.ToString(), 16);
            if (high is { } h)
            {
                output.Add((byte)((h << 4) | nibble));
                high = null;
            }
            else
            {
                high = nibble;
            }
        }
        return output.ToArray();
    }

    public static string String(IEnumerable<byte> bytes) => Convert.ToHexString(bytes.ToArray());
}

/// <summary>One fixture file from <c>spec/fixtures/&lt;folder&gt;/&lt;name&gt;.json</c>.</summary>
internal sealed class Fixture
{
    public Fixture(string folder, string name, JsonObject root)
    {
        Folder = folder;
        Name = name;
        Root = root;
    }

    public string Folder { get; }
    public string Name { get; }
    public JsonObject Root { get; }

    public string Description => $"{Folder}/{Name}";
    public string? Kind => Root["kind"]?.GetValue<string>();
    public byte[] Hex => Combustion.Codec.Tests.Hex.Bytes(Root["hex"]?.GetValue<string>());
    public JsonNode? Expected => Root["expected"];
    public JsonNode? ExpectedError => Root["expectedError"];
    public string? Str(string key) => Root[key]?.GetValue<string>();
}

internal static class Fixtures
{
    /// <summary><c>spec/fixtures</c>, found by walking up from the test binary to the repository root.</summary>
    public static readonly string Directory = FindDirectory();

    private static string FindDirectory()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "spec", "fixtures");
            if (System.IO.Directory.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException("spec/fixtures not found above " + AppContext.BaseDirectory);
    }

    public static string[] FileNames(string folder) =>
        System.IO.Directory.GetFiles(Path.Combine(Directory, folder), "*.json").Select(Path.GetFileName).Order(StringComparer.Ordinal).ToArray()!;

    public static Fixture Load(string folder, string file)
    {
        var name = file.EndsWith(".json", StringComparison.Ordinal) ? file[..^5] : file;
        var text = File.ReadAllText(Path.Combine(Directory, folder, name + ".json"));
        return new Fixture(folder, name, JsonNode.Parse(text)!.AsObject());
    }

    /// <summary>Theory data: one row per fixture file (the "folder/name" string), optionally only those of one <c>kind</c>.</summary>
    public static IEnumerable<object[]> Rows(string folder, string? kind = null)
    {
        foreach (var file in FileNames(folder))
        {
            if (kind is null || Load(folder, file).Kind == kind)
            {
                yield return [folder + "/" + file[..^5]];
            }
        }
    }

    public static Fixture Load(string id)
    {
        var slash = id.IndexOf('/');
        return Load(id[..slash], id[(slash + 1)..]);
    }
}

internal static class Json
{
    /// <summary>
    /// Describes the first difference between expected and actual, or null when they match.
    /// Numbers compare within <paramref name="tolerance"/>; with <paramref name="subset"/> only the keys present in
    /// <paramref name="expected"/> are checked. A missing object key reads as null.
    /// </summary>
    public static string? FirstDifference(JsonNode? expected, JsonNode? actual, string path = "$", double tolerance = 1e-6, bool subset = false)
    {
        // Round-trip so every number is document-backed and comparable.
        if (path == "$")
        {
            actual = actual is null ? null : JsonNode.Parse(actual.ToJsonString());
        }
        if (expected is null || actual is null)
        {
            return expected is null && actual is null ? null : $"{path}: expected {Show(expected)}, got {Show(actual)}";
        }
        var kind = expected.GetValueKind();
        if (kind != actual.GetValueKind() && !(IsBool(kind) && IsBool(actual.GetValueKind())))
        {
            return $"{path}: expected {Show(expected)}, got {Show(actual)}";
        }
        switch (kind)
        {
            case JsonValueKind.Number:
            {
                var e = expected.GetValue<double>();
                var a = actual.GetValue<double>();
                return Math.Abs(e - a) <= tolerance ? null : $"{path}: expected {e}, got {a}";
            }
            case JsonValueKind.Array:
            {
                var e = expected.AsArray();
                var a = actual.AsArray();
                if (e.Count != a.Count)
                {
                    return $"{path}: expected {e.Count} elements, got {a.Count}: {Show(actual)}";
                }
                for (var i = 0; i < e.Count; i++)
                {
                    if (FirstDifference(e[i], a[i], $"{path}[{i}]", tolerance, subset) is { } d)
                    {
                        return d;
                    }
                }
                return null;
            }
            case JsonValueKind.Object:
            {
                var e = expected.AsObject();
                var a = actual.AsObject();
                foreach (var key in e.Select(p => p.Key).Order(StringComparer.Ordinal))
                {
                    if (!a.ContainsKey(key))
                    {
                        return $"{path}.{key}: missing in actual";
                    }
                    if (FirstDifference(e[key], a[key], $"{path}.{key}", tolerance, subset) is { } d)
                    {
                        return d;
                    }
                }
                if (!subset && a.Select(p => p.Key).Order(StringComparer.Ordinal).FirstOrDefault(k => !e.ContainsKey(k)) is { } extra)
                {
                    return $"{path}.{extra}: not in expected";
                }
                return null;
            }
            default:
                return expected.ToJsonString() == actual.ToJsonString() ? null : $"{path}: expected {Show(expected)}, got {Show(actual)}";
        }
    }

    private static bool IsBool(JsonValueKind k) => k is JsonValueKind.True or JsonValueKind.False;

    private static string Show(JsonNode? node) => node?.ToJsonString() ?? "null";
}
