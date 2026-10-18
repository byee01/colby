using System.Text.Json.Nodes;

namespace Combustion.Codec.Tests;

/// <summary>Every fixture file under advertisement/, probe_status/ and node_status/ decodes to its expected value or error.</summary>
public class DecodeFixtureTests
{
    [Theory]
    [InlineData("advertisement", 50)]
    [InlineData("probe_status", 60)]
    [InlineData("node_status", 30)]
    [InlineData("uart_frames", 100)]
    public void FolderIsPopulatedAndEveryFileParses(string folder, int minimum)
    {
        var files = Fixtures.FileNames(folder);
        Assert.True(files.Length >= minimum, $"{folder} has only {files.Length} files");
        foreach (var file in files)
        {
            Assert.NotNull(Fixtures.Load(folder, file));
        }
    }

    public static IEnumerable<object[]> Advertisement() => Fixtures.Rows("advertisement");
    public static IEnumerable<object[]> ProbeStatus() => Fixtures.Rows("probe_status");
    public static IEnumerable<object[]> NodeStatus() => Fixtures.Rows("node_status");

    [Theory, MemberData(nameof(Advertisement))]
    public void AdvertisementFixture(string id)
    {
        var fixture = Fixtures.Load(id);
        Check(fixture, () => Render.Advertisement(CombustionCodec.DecodeAdvertisement(fixture.Hex)));
    }

    [Theory, MemberData(nameof(ProbeStatus))]
    public void ProbeStatusFixture(string id)
    {
        var fixture = Fixtures.Load(id);
        Check(fixture, () => Render.Status(CombustionCodec.DecodeProbeStatus(fixture.Hex)));
    }

    [Theory, MemberData(nameof(NodeStatus))]
    public void NodeStatusFixture(string id)
    {
        var fixture = Fixtures.Load(id);
        Check(fixture, () => Render.NodeStatus(CombustionCodec.DecodeNodeProbeStatus(fixture.Hex)));
    }

    internal static void Check(Fixture fixture, Func<JsonNode?> decode)
    {
        var context = $"{fixture.Description}: {fixture.Root["description"]}";
        try
        {
            var actual = decode();
            Assert.True(fixture.ExpectedError is null, $"{context}: expected an error but decoded {actual?.ToJsonString()}");
            if (fixture.Expected is not null)
            {
                Assert.True(Json.FirstDifference(fixture.Expected, actual) is not { } d, $"{context} -> {Json.FirstDifference(fixture.Expected, actual)}");
            }
        }
        catch (CodecException error)
        {
            Assert.True(fixture.ExpectedError is not null, $"{context}: unexpected {error.Error}");
            var difference = Json.FirstDifference(fixture.ExpectedError, Render.Error(error.Error), subset: true);
            Assert.True(difference is null, $"{context} -> {difference}");
        }
    }
}
