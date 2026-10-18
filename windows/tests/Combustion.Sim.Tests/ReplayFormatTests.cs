using System.Text;
using static Combustion.Sim.Tests.Sim;

namespace Combustion.Sim.Tests;

public class ReplayFormatTests
{
    [Fact]
    public void WritesDocumentedLineFormatWithSortedKeys()
    {
        var dir = TempDir();
        using var _ = Cleanup(dir);
        var w = new ReplayWriter(dir, new ReplayMeta(name: "n", devices: [new ReplayMeta.Device("P", Firmware: "1.2")]));
        w.Append(new ReplayEvent(0.0834, ReplayEvent.Kind.Adv, Peripheral: "P", Hex: "C709", Rssi: -61));
        w.Append(new ReplayEvent(1, ReplayEvent.Kind.Notify, Peripheral: "P", Char: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E", Hex: "CAFE"));
        w.Append(new ReplayEvent(2, ReplayEvent.Kind.State, State: "poweredOff"));
        w.Close();
        var lines = File.ReadAllText(Path.Combine(dir, "events.jsonl"), Encoding.UTF8)
            .Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(
            [
                """{"hex":"C709","peripheral":"P","rssi":-61,"t":0.083,"type":"adv"}""",
                """{"char":"6E400003-B5A3-F393-E0A9-E50E24DCCA9E","hex":"CAFE","peripheral":"P","t":1,"type":"notify"}""",
                """{"state":"poweredOff","t":2,"type":"state"}""",
            ],
            lines);
        Assert.True(File.Exists(Path.Combine(dir, "meta.json")));
        // Same layout as Darwin's pretty-printed, sorted-keys JSONEncoder.
        Assert.Equal(
            "{\n  \"devices\" : [\n    {\n      \"firmware\" : \"1.2\",\n      \"peripheral\" : \"P\"\n    }\n  ],\n  \"formatVersion\" : 1,\n  \"name\" : \"n\"\n}",
            File.ReadAllText(Path.Combine(dir, "meta.json"), Encoding.UTF8));
    }

    [Fact]
    public void ReaderRoundTrip()
    {
        var dir = TempDir();
        using var _ = Cleanup(dir);
        var meta = new ReplayMeta(name: "cook", devices: [new ReplayMeta.Device("P", "Predictive", "1.0")],
            os: "macOS 14", adapter: "built-in", notes: "x");
        ReplayEvent[] events =
        [
            new(0, ReplayEvent.Kind.Connect, Peripheral: "P"),
            new(0.5, ReplayEvent.Kind.Write, Peripheral: "P", Char: "C", Hex: "00FF"),
            new(1.25, ReplayEvent.Kind.Disconnect, Peripheral: "P"),
        ];
        var w = new ReplayWriter(dir, meta);
        foreach (var e in events)
        {
            w.Append(e);
        }
        w.Close();
        var r = new ReplayReader(dir);
        Assert.Equal(meta, r.Meta);
        Assert.Equal(events, r.Events);
        Assert.Equal([0x00, 0xFF], r.Events[1].Bytes);
    }

    [Fact]
    public void ReaderReportsBadLineNumber()
    {
        var dir = TempDir();
        using var _ = Cleanup(dir);
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "events.jsonl"), "{\"t\":0,\"type\":\"adv\"}\nnot json\n");
        var e = Assert.Throws<ReplayException>(() => new ReplayReader(dir));
        Assert.Equal(ReplayErrorKind.BadLine, e.Kind);
        Assert.Equal(2, e.Number);
        Assert.Equal("not json", e.Text);
    }

    [Fact]
    public void ReaderRequiresEventsFileButMetaIsOptional()
    {
        var dir = TempDir();
        using var _ = Cleanup(dir);
        Directory.CreateDirectory(dir);
        var e = Assert.Throws<ReplayException>(() => new ReplayReader(dir));
        Assert.Equal(ReplayErrorKind.MissingFile, e.Kind);
        Assert.Equal("events.jsonl", e.Text);
        File.WriteAllText(Path.Combine(dir, "events.jsonl"), "");
        var r = new ReplayReader(dir);
        Assert.Empty(r.Events);
        Assert.Equal(new ReplayMeta(), r.Meta);
    }
}
