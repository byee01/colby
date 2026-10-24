namespace Combustion.Core.Tests;

using F = StoreFixtures;

/// <summary>A route that records requests and lets the test decide what the probe does about them.</summary>
public sealed class FakeRoute : ICommandRoute, ICommandRouting
{
    public delegate Task Handler(UartRequest request);

    private readonly List<UartRequest> _log = [];
    private bool _reachable = true;
    private Handler _handler = _ => Task.CompletedTask;

    public IReadOnlyList<UartRequest> Requests => [.. _log];

    public void SetReachable(bool value) => _reachable = value;

    public void OnSend(Handler h) => _handler = h;

    public ICommandRoute? CommandRoute(ProbeSerial probe) => _reachable ? this : null;

    public async Task<UartResponse> SendAsync(UartRequest request, ProbeSerial probe, TimeSpan timeout)
    {
        _log.Add(request);
        await _handler(request);
        return new UartResponse(request.MessageType, true, new ResponseBody.Ack());
    }
}

/// <summary>
/// Port of <c>mac/Tests/CombustionCoreTests/Commands/CommandsTests.swift</c>. Only the rig and the tests added since the
/// Windows port started are here so far; the rest of the Swift file is listed in docs/HANDOFF.md (parity row 11).
/// </summary>
public sealed class CommandsTests
{
    private sealed class Rig
    {
        private Rig()
        {
            Store = new ProbeStore(Clock);
            Commands = new Commands(Store, Route, Clock);
        }

        public TestClock Clock { get; } = new();

        public ProbeStore Store { get; }

        public FakeRoute Route { get; } = new();

        public Commands Commands { get; }

        public static Rig Make(AlarmConfig? alarms = null, bool noAlarms = false, PredictionStatus? prediction = null)
        {
            var rig = new Rig();
            if (!noAlarms)
            {
                rig.Push(alarms ?? new AlarmConfig(), prediction ?? F.Prediction());
            }
            return rig;
        }

        /// <summary>A full status from the probe, now.</summary>
        public void Push(AlarmConfig? alarms, PredictionStatus? prediction = null, uint seq = 0) =>
            Store.Ingest(F.Observe(
                F.St(F.Status(logMax: seq, prediction: prediction ?? F.Prediction(), alarms: alarms, noAlarms: alarms is null)),
                LinkKind.DirectConnection, Clock.Now()));

        /// <summary>The probe applies a request to its state and reports it in a status, as the real one does.</summary>
        public void ProbeApplies(Func<UartRequest, (AlarmConfig? Alarms, PredictionStatus Prediction)> transform) =>
            Route.OnSend(request =>
            {
                var (alarms, prediction) = transform(request);
                Store.Ingest(F.Observe(
                    F.St(F.Status(logMax: 1, prediction: prediction, alarms: alarms, noAlarms: alarms is null)),
                    LinkKind.DirectConnection, Clock.Now()));
                return Task.CompletedTask;
            });
    }

    // Set prediction

    [Fact]
    public void SetPredictionIsConfirmedByTheNextStatus() => Det.Run(async () =>
    {
        var rig = Rig.Make();
        rig.ProbeApplies(request => request is UartRequest.SetPrediction { Setpoint: var sp, Mode: var mode }
            ? (new AlarmConfig(), F.Prediction(PredictionState.Predicting, mode, sp, 1800))
            : (new AlarmConfig(), F.Prediction()));
        await rig.Commands.SetPredictionAsync(F.Serial, PredictionMode.TimeToRemoval, 63);
        Assert.Equal([new UartRequest.SetPrediction(63, PredictionMode.TimeToRemoval)], rig.Route.Requests);
    });

    [Fact]
    public void ASetpointReportedOneTenthLowStillConfirms() => Det.Run(async () =>
    {
        // Hardware: 85 °F was sent as 29.4 °C and the probe reported 29.3 °C.
        var rig = Rig.Make();
        rig.ProbeApplies(request => request is UartRequest.SetPrediction { Setpoint: var sp, Mode: var mode }
            ? (new AlarmConfig(), F.Prediction(PredictionState.Predicting, mode, sp - 0.1, 1800))
            : (new AlarmConfig(), F.Prediction()));
        await rig.Commands.SetPredictionAsync(F.Serial, PredictionMode.RemovalAndResting, 29.4);
    });
}
