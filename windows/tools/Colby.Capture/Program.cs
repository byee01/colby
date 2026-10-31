// colby-capture: records real Combustion devices into a replay directory (docs/07 §2, docs/05 §4).
//
//   dotnet run --project windows/tools/Colby.Capture -- --name <replay> [--serial HEX]... [--minutes M]
//                                                       [--adv-only] [--direct-only] [--notes TEXT] [--out DIR]
//
// Port of mac/Sources/ColbyCapture. WinRtBleTransport is wrapped in RecordingTransport and driven by a normal
// CombustionApp on a CoreThread, so the default policy decides what to connect to. Every probe heard (or only the
// --serial ones) is followed. With --adv-only nothing is followed, so nothing connects. No commands are sent.
// Ctrl-C ends the capture and writes meta.json.
using System.Globalization;
using Combustion.Codec;
using Combustion.Core;
using Combustion.Sim;
using Combustion.Transport.WinRT;

namespace Colby.Capture;

internal sealed class Options
{
    public const string Usage = """
        usage: colby-capture --name REPLAY [--serial HEX]... [--minutes M] [--adv-only] [--direct-only]
                             [--notes TEXT] [--out DIR]
        """;

    public string Name { get; private set; } = "";
    public HashSet<string> Serials { get; } = [];
    public double? Minutes { get; private set; }
    public bool AdvOnly { get; private set; }
    public bool DirectOnly { get; private set; }
    public string? Notes { get; private set; }
    public string? Out { get; private set; }

    public static Options Parse(string[] args)
    {
        var o = new Options();
        for (var i = 0; i < args.Length; i++)
        {
            string? Next() => i + 1 < args.Length ? args[++i] : null;
            switch (args[i])
            {
                case "--name": o.Name = Next() ?? ""; break;
                case "--serial":
                    if (Next() is { } s)
                    {
                        o.Serials.Add(s.ToUpperInvariant());
                    }
                    break;
                case "--minutes":
                    if (!double.TryParse(Next(), NumberStyles.Float, CultureInfo.InvariantCulture, out var m) || m <= 0)
                    {
                        Console.WriteLine("--minutes needs a positive number\n" + Usage);
                        Environment.Exit(2);
                    }
                    o.Minutes = m;
                    break;
                case "--adv-only": o.AdvOnly = true; break;
                case "--direct-only": o.DirectOnly = true; break;
                case "--notes": o.Notes = Next(); break;
                case "--out": o.Out = Next(); break;
                default:
                    Console.WriteLine(Usage);
                    Environment.Exit(args[i] == "--help" ? 0 : 2);
                    break;
            }
        }
        if (o.Name.Length == 0 || o.Name.Contains('/') || o.Name.Contains('\\'))
        {
            Console.WriteLine(Usage);
            Environment.Exit(2);
        }
        return o;
    }
}

/// <summary><see cref="DirectConnectionPolicy"/> without the MeatNet node step: node sightings never reach it.</summary>
internal sealed class DirectOnlyPolicy : IConnectionPolicy
{
    private readonly DirectConnectionPolicy _inner = new();

    public Task StartAsync(ConnectionPolicyInput input) =>
        _inner.StartAsync(input with { NodeSightings = null, RepeatedSightings = null });

    public Task StopAsync() => _inner.StopAsync();

    public IReadOnlyDictionary<ProbeSerial, ProbeConnectionState> States() => _inner.States();

    public IReadOnlyDictionary<string, ProbeConnectionState> NodeStates() => _inner.NodeStates();
}

/// <summary>Devices heard, for meta.json and the live table. Peripheral ids are Bluetooth addresses on Windows.</summary>
internal sealed class Sightings
{
    public sealed class Device(string name)
    {
        public string Name { get; set; } = name;
        public int Adverts { get; set; }
        public int? Rssi { get; set; }
    }

    public Dictionary<PeripheralId, Device> Devices { get; } = [];
    public Dictionary<ProbeSerial, PeripheralId> Probes { get; } = [];
    public int Undecoded { get; private set; }

    /// <summary>Returns the probe serial when this advert came from a probe itself.</summary>
    public ProbeSerial? Ingest(RawAdvertisement adv)
    {
        AdvertisementPacket packet;
        try
        {
            packet = CombustionCodec.DecodeAdvertisement(adv.MfrData);
        }
        catch (CodecException)
        {
            Undecoded++;
            return null;
        }
        string name;
        ProbeSerial? probe = null;
        switch (packet)
        {
            case AdvertisementPacket.Probe { Advertisement: var p }:
                name = $"probe {p.Serial.Hex}";
                probe = p.Serial;
                Probes[p.Serial] = adv.Peripheral;
                break;
            case AdvertisementPacket.Repeated { Advertisement: var p }:
                // A node repeating a probe: the peripheral is the node, named by its own advert.
                name = Devices.TryGetValue(adv.Peripheral, out var known) ? known.Name : $"node (repeating {p.Serial.Hex})";
                break;
            case AdvertisementPacket.Node { Advertisement: var n }:
                name = $"{n.ProductType} {n.Serial}";
                break;
            default:
                name = "unknown product";
                break;
        }
        if (!Devices.TryGetValue(adv.Peripheral, out var d))
        {
            d = new Device(name);
            Devices[adv.Peripheral] = d;
        }
        if (packet is not AdvertisementPacket.Repeated)
        {
            d.Name = name;
        }
        d.Adverts++;
        d.Rssi = adv.Rssi;
        return probe;
    }
}

internal static class Program
{
    private static void Log(string line) => Console.Error.WriteLine(line);

    /// <summary><c>spec/replays</c> of the enclosing repository: the first parent of the working directory that has <c>spec/</c>.</summary>
    private static string DefaultReplayRoot()
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
        for (var i = 0; i < 4 && dir is not null; i++, dir = dir.Parent)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, "spec")))
            {
                return Path.Combine(dir.FullName, "spec", "replays");
            }
        }
        return Path.Combine("spec", "replays");
    }

    private static string ConnectionName(ProbeConnectionState? state) => state switch
    {
        null => "-",
        ProbeConnectionState.WaitingForAdvertisement => "waiting",
        ProbeConnectionState.Connecting c => $"connecting #{c.Attempt}",
        ProbeConnectionState.Connected => "connected",
        ProbeConnectionState.Backoff b => $"backoff #{b.Attempt}",
        ProbeConnectionState.GaveUp => "gave up",
        ProbeConnectionState.ViaNode v => $"via {v.Node}",
        _ => "?",
    };

    private static string SourceName(LinkKind? kind) => kind switch
    {
        LinkKind.DirectConnection => "direct",
        LinkKind.NodeConnection => "node",
        LinkKind.NodeAdvertisement => "n-adv",
        _ => "adv",
    };

    private static string PredictionText(PredictionStatus? p) => p switch
    {
        null => "-",
        { State: PredictionState.Predicting } => $"{p.Value.RawSecondsRemaining / 60}:{p.Value.RawSecondsRemaining % 60:00} left",
        { State: PredictionState.RemovalPredictionDone } => "done",
        { State: PredictionState.NotInserted } => "not inserted",
        { State: PredictionState.Inserted } => "inserted",
        { State: PredictionState.Warming } => "warming",
        _ => "unknown",
    };

    private static string Temp(double? v) => v is { } t ? t.ToString("0.0", CultureInfo.InvariantCulture) : "-";

    /// <summary>Left-aligned columns; the last one is not padded.</summary>
    private static string Row(params string[] cells)
    {
        int[] widths = [6, 9, 9, 6, 5, 7, 7, 7, 13, 4];
        var padded = cells.Take(widths.Length).Select((c, i) => c.PadRight(widths[i]));
        return string.Join(" ", padded) + " " + string.Join(" ", cells.Skip(widths.Length));
    }

    public static int Main(string[] args)
    {
        var options = Options.Parse(args);
        var end = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            end.TrySetResult();
        };
        if (options.Minutes is { } minutes)
        {
            _ = Task.Delay(TimeSpan.FromMinutes(minutes)).ContinueWith(_ => end.TrySetResult(), TaskScheduler.Default);
        }
        using var core = new CoreThread();
        return core.InvokeAsync(() => RunAsync(options, end.Task)).GetAwaiter().GetResult();
    }

    private static async Task<int> RunAsync(Options options, Task end)
    {
        var directory = Path.Combine(options.Out ?? DefaultReplayRoot(), options.Name);
        if (Directory.Exists(directory))
        {
            Log($"colby-capture: {directory} exists; pick another --name");
            return 1;
        }

        var meta = new ReplayMeta(name: options.Name, os: $"Windows {Environment.OSVersion.Version}", adapter: "WinRT",
            notes: options.Notes);
        var clock = new SystemClock();
        using var writer = new ReplayWriter(directory, meta);
        var ble = new WinRtBleTransport(clock);
        var transport = new RecordingTransport(ble, writer, clock);
        using var app = new CombustionApp(transport, clock, policy: options.DirectOnly ? new DirectOnlyPolicy() : null);
        var sightings = new Sightings();
        using var stop = new CancellationTokenSource();

        _ = transport.State().ForEachAsync(s =>
        {
            Log($"bluetooth: {s}");
            switch (s)
            {
                case BluetoothState.Unauthorized:
                    Log("  allow Bluetooth for desktop apps in Settings > Privacy & security > Bluetooth");
                    break;
                case BluetoothState.PoweredOff:
                    Log("  turn Bluetooth on");
                    break;
                case BluetoothState.Unsupported:
                    Log("  this PC has no Bluetooth LE adapter");
                    break;
            }
        }, stop.Token);

        var follow = !options.AdvOnly;
        _ = transport.Advertisements().ForEachAsync(async adv =>
        {
            if (sightings.Ingest(adv) is not { } serial || !follow)
            {
                return;
            }
            if ((options.Serials.Count == 0 || options.Serials.Contains(serial.Hex.ToUpperInvariant()))
                && !app.Probes.FollowedSerials().Contains(serial))
            {
                Log($"following {serial.Hex}");
                await app.FollowAsync(serial);
            }
        }, stop.Token);

        await app.StartAsync();
        var mode = options.AdvOnly ? "advertisements only" : options.DirectOnly ? "direct links only" : "direct + MeatNet";
        Console.WriteLine($"colby-capture: recording to {directory} ({mode}). Ctrl-C to stop.");

        var started = DateTimeOffset.UtcNow;
        _ = TableAsync();
        async Task TableAsync()
        {
            var rows = 0;
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(5), stop.Token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                var snapshots = app.Probes.Snapshots();
                var diagnostics = app.Diagnostics();
                var elapsed = (int)(DateTimeOffset.UtcNow - started).TotalSeconds;
                if (rows % 12 == 0)
                {
                    Console.WriteLine("\n" + Row("t", "probe", "id", "src", "rssi", "core", "surface", "ambient", "prediction",
                        "batt", "link"));
                }
                rows++;
                var time = $"{elapsed / 60}:{elapsed % 60:00}";
                if (snapshots.Count == 0)
                {
                    Console.WriteLine($"{time}   no probes yet ({sightings.Devices.Count} Combustion devices heard)");
                    continue;
                }
                foreach (var (serial, snap) in snapshots.OrderBy(kv => kv.Key))
                {
                    var rssi = sightings.Probes.TryGetValue(serial, out var p) && sightings.Devices.TryGetValue(p, out var dev)
                        && dev.Rssi is { } r ? r.ToString(CultureInfo.InvariantCulture) : "-";
                    var source = snap.IsOffline ? "off" : SourceName(snap.Link.Primary?.Kind);
                    Console.WriteLine(Row(time, serial.Hex, $"{snap.ProbeNumber} {snap.Color}", source, rssi,
                        Temp(snap.Virtual.Core), Temp(snap.Virtual.Surface), Temp(snap.Virtual.Ambient),
                        PredictionText(snap.Prediction), snap.BatteryLow ? "low" : "ok",
                        ConnectionName(diagnostics.Links.TryGetValue(serial, out var st) ? st : null)));
                }
            }
        }

        await end;
        Console.WriteLine("\nstopping");
        stop.Cancel();
        var nodes = app.Probes.NodeSnapshots();
        var final = app.Diagnostics();
        await app.StopAsync();
        transport.Stop();
        ble.Dispose();

        var devices = sightings.Devices.OrderBy(kv => kv.Key.Raw, StringComparer.Ordinal).Select(kv =>
        {
            var firmware = nodes.Values.FirstOrDefault(n => kv.Value.Name.EndsWith($" {n.Serial}", StringComparison.Ordinal))?.Firmware?.Firmware;
            return new ReplayMeta.Device(kv.Key.Raw, kv.Value.Name, firmware);
        }).ToList();
        meta = meta with { Devices = [.. devices] };
        writer.WriteMeta(meta);
        if (writer.LastError is { } error)
        {
            Log($"colby-capture: write error: {error}");
        }
        writer.Dispose();

        var events = new ReplayReader(directory).Events;
        Console.WriteLine($"wrote {events.Count} events to {directory}");
        foreach (var g in events.GroupBy(e => e.Type).OrderBy(g => g.Key.ToString(), StringComparer.Ordinal))
        {
            Console.WriteLine($"  {g.Key.ToString().ToLowerInvariant()}: {g.Count()}");
        }
        if (sightings.Undecoded > 0)
        {
            Console.WriteLine($"  adverts that did not decode: {sightings.Undecoded}");
        }
        Console.WriteLine($"uart: {string.Join(", ", final.Uart.Select(kv => $"{kv.Key.Hex} {kv.Value}"))}");
        Console.WriteLine("devices:");
        foreach (var d in meta.Devices)
        {
            Console.WriteLine($"  {d.Name ?? "?"}  {d.Peripheral}{(d.Firmware is { } f ? $"  fw {f}" : "")}");
        }
        Console.WriteLine("add firmware versions for probes to meta.json by hand (from the Combustion phone app)");
        return 0;
    }
}
