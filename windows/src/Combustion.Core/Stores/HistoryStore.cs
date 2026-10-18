using Combustion.Codec;

namespace Combustion.Core;

/// <summary>
/// Persistent cooks: sessions, log samples, time derivation, backfill. docs/02 §6.3, §11.
/// <para>
/// Owns the SQLite database (confined to the core context; Swift: actor). Samples are keyed <c>(session row, seq)</c>
/// and inserted with <c>INSERT OR IGNORE</c>, so every path (live fetch, backfill, re-delivery) is idempotent. Times are
/// never stored: they are derived on read from the session's latest anchor <c>(seq = logRange.Max, time = receivedAt)</c>.
/// </para>
/// </summary>
public sealed class HistoryStore : IFollowedProbePersistence, IDisposable
{
    /// <summary>Used when a status carries no sample period (old firmware). The probe logs every 5 s by default.</summary>
    public const long DefaultSamplePeriodMs = 5000;

    /// <summary><see cref="ValueAt"/> interpolates only between stored neighbours at most this many seqs apart.</summary>
    public const uint MaxInterpolationGap = 12;

    private readonly SqliteDatabase _db;
    private readonly IClock _clock;
    private ILogFetcher? _logFetcher;

    /// <summary>Swift value type: replaced, never mutated in place, so a failed transaction leaves the old state.</summary>
    private sealed record Runtime(SessionTracker Tracker, long? RowId, DateTimeOffset LastStatusAt);

    private readonly Dictionary<ProbeSerial, Runtime> _runtime = [];
    private readonly Dictionary<long, LogRange> _lastRanges = [];
    private readonly Dictionary<long, Broadcaster<TemperatureSeries>> _seriesBroadcasters = [];
    private readonly HashSet<long> _liveRunning = [];
    private readonly Dictionary<long, LogRange> _livePending = [];
    private readonly HashSet<long> _backfilling = [];

    /// <summary>Takes ownership of <paramref name="database"/> (closed by <see cref="Dispose"/>).</summary>
    public HistoryStore(SqliteDatabase database, IClock clock, ILogFetcher? logFetcher = null)
    {
        _db = database;
        _clock = clock;
        _logFetcher = logFetcher;
        Schema.Migrate(database);
    }

    /// <summary><c>":memory:"</c> or a file path.</summary>
    public HistoryStore(string path, IClock clock, ILogFetcher? logFetcher = null)
        : this(new SqliteDatabase(path), clock, logFetcher)
    {
    }

    /// <summary>Closes the database (Swift: deinit).</summary>
    public void Dispose() => _db.Dispose();

    /// <summary>Log downloads running right now (live fetches plus backfills), for diagnostics.</summary>
    public int FetchesInFlight => _liveRunning.Count + _backfilling.Count;

    /// <summary>Last database error from <see cref="ConsumeAsync"/>.</summary>
    public Exception? LastError { get; private set; }

    /// <summary>Default fetcher for live record fetches (direct or node link). Replace as links come and go.</summary>
    public void SetLogFetcher(ILogFetcher? fetcher) => _logFetcher = fetcher;

    // Status ingest

    /// <summary>Consumes <c>ProbeStore.StatusEvents()</c> until the stream ends or <paramref name="ct"/> fires.</summary>
    public async Task ConsumeAsync(IAsyncEnumerable<ProbeStatusEvent> events, CancellationToken ct = default)
    {
        try
        {
            await foreach (var e in events.WithCancellation(ct))
            {
                try
                {
                    await IngestAsync(e);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    LastError = ex;
                }
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }

    /// <summary>
    /// Handles one full status: session detection, anchors, kind, ready-since, then (if <c>logRange.Max</c> advanced)
    /// fetches the new records through <paramref name="fetcher"/> (default: the store's fetcher).
    /// Returns the session the status belongs to.
    /// </summary>
    public async Task<SessionKey> IngestAsync(ProbeStatusEvent status, ILogFetcher? fetcher = null)
    {
        var (key, rowId) = RecordStatus(status);
        if ((fetcher ?? _logFetcher) is { } f)
        {
            await LiveFetchAsync(status.Serial, rowId, status.Status.LogRange, f);
        }
        return key;
    }

    private (SessionKey Key, long RowId) RecordStatus(ProbeStatusEvent e)
    {
        var serial = e.Serial;
        var status = e.Status;
        var sessionId = status.Session?.SessionId ?? 0;
        var at = e.ReceivedAt;
        var rt = _runtime.GetValueOrDefault(serial) ?? Restore(serial, at);
        var tracker = rt.Tracker with { };
        var decision = tracker.Observe(sessionId, status.LogRange, at);
        long? periodMs = status.Session is { } info ? info.SamplePeriodMs : null;
        var predictive = IsPredictive(status.Prediction.Mode);

        var rowId = _db.Transaction(() =>
        {
            var current = rt.RowId;
            if (decision is SessionTracker.Decision.NewSession && current is { } old)
            {
                EndSession(old, rt.LastStatusAt);
                current = null;
            }
            if (decision is SessionTracker.Decision.AdoptedSessionId { SessionId: var adopted } && current is { } r)
            {
                _db.Run("UPDATE session SET session_id=? WHERE id=?", (long)adopted, r);
            }
            if (current is not { } id)
            {
                _db.Run("""
                    INSERT INTO session(serial, session_id, sample_period_ms, started_at, ended_at, anchor_seq,
                                        anchor_time, nickname, kind, ready_since, thumbnail)
                    VALUES(?,?,?,?,NULL,?,?,NULL,?,NULL,NULL)
                    """,
                    (long)serial.Raw, (long)sessionId, periodMs ?? DefaultSamplePeriodMs, Time.ToMs(at),
                    (long)status.LogRange.Max, Time.ToMs(at), KindText(predictive ? SessionKind.Predictive : SessionKind.Manual));
                id = _db.LastInsertRowId;
            }
            else
            {
                // Re-anchor (never backwards in time).
                _db.Run("""
                    UPDATE session SET anchor_seq=?, anchor_time=?
                    WHERE id=? AND anchor_time<=?
                    """, (long)status.LogRange.Max, Time.ToMs(at), id, Time.ToMs(at));
                if (periodMs is { } p)
                {
                    _db.Run("UPDATE session SET sample_period_ms=? WHERE id=?", p, id);
                }
                if (predictive)
                {
                    _db.Run("UPDATE session SET kind='predictive' WHERE id=?", id);
                }
            }
            switch (status.Prediction.State)
            {
                case PredictionState.RemovalPredictionDone:
                    _db.Run("UPDATE session SET ready_since=? WHERE id=? AND ready_since IS NULL", Time.ToMs(at), id);
                    break;
                case PredictionState.NotInserted or PredictionState.Inserted or PredictionState.Warming or PredictionState.Predicting:
                    _db.Run("UPDATE session SET ready_since=NULL WHERE id=? AND ready_since IS NOT NULL", id);
                    break;
                default:
                    break;
            }
            _db.Run("""
                INSERT INTO probe(serial, followed, last_seen) VALUES(?,0,?)
                ON CONFLICT(serial) DO UPDATE SET last_seen=excluded.last_seen
                """, (long)serial.Raw, Time.ToMs(at));
            return id;
        });

        var isLatest = at >= rt.LastStatusAt;
        _runtime[serial] = new Runtime(tracker, rowId, at > rt.LastStatusAt ? at : rt.LastStatusAt);
        if (isLatest || !_lastRanges.ContainsKey(rowId))
        {
            _lastRanges[rowId] = status.LogRange;
        }
        PublishSeries(rowId);
        var row = LoadRow(rowId)!;
        return (row.Key, rowId);
    }

    /// <summary>Latest open session of <paramref name="serial"/> becomes the tracker's current session.</summary>
    private Runtime Restore(ProbeSerial serial, DateTimeOffset fallbackTime)
    {
        var rows = _db.Query($"SELECT {SessionRow.Columns} FROM session WHERE serial=? ORDER BY started_at DESC, id DESC LIMIT 1", (long)serial.Raw);
        if (rows.Count > 0 && SessionRow.From(rows[0]) is { EndedAt: null } r)
        {
            var seen = Time.FromMs(r.AnchorTime);
            return new Runtime(new SessionTracker(r.SessionId, new LogRange(0, r.AnchorSeq), seen), r.Id, seen);
        }
        return new Runtime(new SessionTracker(), null, fallbackTime);
    }

    private void EndSession(long rowId, DateTimeOffset at)
    {
        var thumb = Thumbnail.Make(LoadSamples(rowId));
        _db.Run("UPDATE session SET ended_at=?, thumbnail=? WHERE id=? AND ended_at IS NULL",
            Time.ToMs(at), thumb.Count == 0 ? null : Thumbnail.Encode(thumb), rowId);
    }

    /// <summary>Closes the open session of <paramref name="serial"/> (ended_at, thumbnail). The next status starts a new session.</summary>
    public void EndCurrentSession(ProbeSerial serial, DateTimeOffset? at = null)
    {
        if (!_runtime.TryGetValue(serial, out var rt) || rt.RowId is not { } rowId)
        {
            return;
        }
        EndSession(rowId, at ?? rt.LastStatusAt);
        _runtime[serial] = new Runtime(new SessionTracker(), null, rt.LastStatusAt);
        PublishSeries(rowId);
    }

    /// <summary>The open session of <paramref name="serial"/>, if any.</summary>
    public SessionKey? CurrentSession(ProbeSerial serial)
    {
        if (_runtime.GetValueOrDefault(serial)?.RowId is not { } id)
        {
            return null;
        }
        return LoadRow(id)?.Key;
    }

    // Live fetch and backfill

    private uint? MaxStoredSeq(long rowId)
    {
        var rows = _db.Query("SELECT MAX(seq) FROM sample WHERE session=?", rowId);
        return rows.Count > 0 && rows[0].Int64(0) is { } v ? (uint)v : null;
    }

    private async Task LiveFetchAsync(ProbeSerial serial, long rowId, LogRange range, ILogFetcher fetcher)
    {
        if (_liveRunning.Contains(rowId))
        {
            _livePending[rowId] = range;
            return;
        }
        _liveRunning.Add(rowId);
        try
        {
            var target = range;
            while (true)
            {
                uint? stored;
                try
                {
                    stored = MaxStoredSeq(rowId);
                }
                catch (Exception)
                {
                    stored = null; // Swift: try?
                }
                if (stored is { } st && st >= target.Max)
                {
                    break;
                }
                // New seqs since the last stored one, at most one chunk; older holes are backfill's job.
                var from = stored is { } s ? (long)s + 1 : target.Min;
                var start = Math.Max(Math.Max(from, (long)target.Max - BackfillPlanner.DefaultChunkSize + 1), target.Min);
                if (start > target.Max)
                {
                    break;
                }
                await FetchChunkAsync(serial, rowId, new SeqRange((uint)start, target.Max), fetcher);
                if (_livePending.Remove(rowId, out var p) && p.Max > target.Max)
                {
                    target = p;
                }
                else
                {
                    break;
                }
            }
            _livePending.Remove(rowId);
        }
        finally
        {
            _liveRunning.Remove(rowId);
        }
    }

    /// <summary>
    /// Fills holes in a session's log, newest chunk first, 128 records per request. Partial results are kept; holes that
    /// remain are retried by the next call. Stops at the first fetcher error (e.g. link lost) or when <paramref name="ct"/>
    /// fires. <paramref name="range"/> defaults to the log range of the session's latest status.
    /// </summary>
    public async Task<BackfillResult> BackfillAsync(SessionKey session, ILogFetcher fetcher, LogRange? range = null, CancellationToken ct = default)
    {
        var none = new BackfillResult(0, 0, 0, false);
        long? found;
        try
        {
            found = RowIdFor(session);
        }
        catch (Exception)
        {
            found = null;
        }
        if (found is not { } rowId)
        {
            return none;
        }
        if ((range ?? (_lastRanges.TryGetValue(rowId, out var last) ? last : null)) is not { } r)
        {
            return none;
        }
        if (!_backfilling.Add(rowId))
        {
            return none;
        }
        try
        {
            var existing = TrySeqs(rowId, r) ?? [];
            var chunks = BackfillPlanner.Plan(existing, r);
            int requested = 0, received = 0;
            var failed = false;
            foreach (var chunk in chunks)
            {
                if (ct.IsCancellationRequested)
                {
                    failed = true;
                    break;
                }
                requested += (int)chunk.Count;
                var (got, error) = await FetchChunkAsync(session.Serial, rowId, chunk, fetcher);
                received += got;
                if (error is not null)
                {
                    failed = true;
                    break;
                }
            }
            var remaining = TrySeqs(rowId, r) is { } after ? (int)BackfillPlanner.Plan(after, r).Sum(c => c.Count) : 0;
            return new BackfillResult(requested, received, remaining, failed);
        }
        finally
        {
            _backfilling.Remove(rowId);
        }
    }

    /// <summary>Reads one range, inserts what arrived (even if the stream failed), publishes the series.</summary>
    private async Task<(int Inserted, Exception? Error)> FetchChunkAsync(ProbeSerial serial, long rowId, SeqRange range, ILogFetcher fetcher)
    {
        var records = new List<LogRecord>();
        Exception? failure = null;
        try
        {
            await foreach (var r in fetcher.ReadLogs(serial, range.Lower, range.Upper))
            {
                if (range.Contains(r.Sequence))
                {
                    records.Add(r);
                }
            }
        }
        catch (Exception ex)
        {
            failure = ex;
        }
        int inserted;
        try
        {
            inserted = Insert(records, rowId);
        }
        catch (Exception)
        {
            inserted = 0; // Swift: try?
        }
        if (inserted > 0)
        {
            PublishSeries(rowId);
        }
        return (inserted, failure);
    }

    private int Insert(List<LogRecord> records, long rowId)
    {
        if (records.Count == 0)
        {
            return 0;
        }
        return _db.Transaction(() =>
        {
            using var stmt = _db.Prepare("""
                INSERT OR IGNORE INTO sample(session, seq, t1,t2,t3,t4,t5,t6,t7,t8, vs, pred_state, pred_mode,
                                             pred_type, setpoint, pred_seconds, est_core)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, 17);
            var inserted = 0;
            var predictive = false;
            foreach (var r in records)
            {
                var p = r.Prediction;
                var vs = p.VirtualSensors;
                var parameters = new List<object?>(17) { rowId, (long)r.Sequence };
                parameters.AddRange(r.Temperatures.Celsius.Select(c => (object?)c));
                parameters.Add((long)vs.Core | ((long)vs.Surface - 3) << 3 | ((long)vs.Ambient - 4) << 5);
                parameters.Add((long)StateCode(p.State));
                parameters.Add((long)p.Mode);
                parameters.Add((long)p.Type);
                parameters.Add(p.Setpoint);
                parameters.Add((long)p.RawSecondsRemaining);
                parameters.Add(p.EstimatedCore);
                inserted += stmt.Run([.. parameters]);
                if (IsPredictive(p.Mode))
                {
                    predictive = true;
                }
            }
            if (predictive)
            {
                _db.Run("UPDATE session SET kind='predictive' WHERE id=?", rowId);
            }
            return inserted;
        });
    }

    private List<uint> Seqs(long rowId, LogRange range) =>
        _db.Query("SELECT seq FROM sample WHERE session=? AND seq BETWEEN ? AND ?", rowId, (long)range.Min, (long)range.Max)
            .Select(row => row.Int64(0))
            .Where(v => v is not null)
            .Select(v => (uint)v!.Value)
            .ToList();

    private List<uint>? TrySeqs(long rowId, LogRange range)
    {
        try
        {
            return Seqs(rowId, range);
        }
        catch (Exception)
        {
            return null;
        }
    }

    // Reads

    /// <summary>Summaries, newest first.</summary>
    public List<SessionSummary> Sessions(ProbeSerial? serial = null)
    {
        var rows = serial is { } s
            ? _db.Query($"SELECT {SessionRow.Columns} FROM session WHERE serial=? ORDER BY started_at DESC, id DESC", (long)s.Raw)
            : _db.Query($"SELECT {SessionRow.Columns} FROM session ORDER BY started_at DESC, id DESC");
        return rows.Select(SessionRow.From).OfType<SessionRow>().Select(Summary).ToList();
    }

    private SessionSummary Summary(SessionRow r)
    {
        var agg = _db.Query($"SELECT COUNT(*), MAX({CoreExpr}) FROM sample WHERE session=?", r.Id)[0];
        var count = (int)(agg.Int64(0) ?? 0);
        var peak = agg[1] is double p ? p : (double?)null;
        var setpoints = _db.Query("SELECT setpoint FROM sample WHERE session=? AND pred_mode<>0 ORDER BY seq DESC LIMIT 1", r.Id);
        double? setpoint = setpoints.Count > 0 && setpoints[0][0] is double sp ? sp : null;
        List<ThumbnailPoint> thumb = r.Thumbnail is { } blob ? Thumbnail.Decode(blob) : [];
        if (thumb.Count == 0 && r.EndedAt is null && count > 0)
        {
            thumb = Thumbnail.Make(LoadSamples(r.Id));
        }
        return new SessionSummary(
            r.Key, Time.FromMs(r.StartedAt), r.EndedAt is { } e ? Time.FromMs(e) : null, peak,
            setpoint, r.Kind, r.Nickname, count,
            r.SamplePeriodMs / 1000.0, r.ReadySince is { } rs ? Time.FromMs(rs) : null, thumb);
    }

    public int SampleCount(SessionKey session)
    {
        if (RowIdFor(session) is not { } id)
        {
            return 0;
        }
        var rows = _db.Query("SELECT COUNT(*) FROM sample WHERE session=?", id);
        return rows.Count > 0 && rows[0].Int64(0) is { } c ? (int)c : 0;
    }

    /// <summary>One-shot series (times derived now from the latest anchor).</summary>
    public TemperatureSeries? CurrentSeries(SessionKey session) =>
        RowIdFor(session) is { } id ? BuildSeries(id) : null;

    /// <summary>
    /// Series as an observable: latest value first, then a new value whenever samples or the anchor change.
    /// Finishes when the session is deleted. Unknown sessions give an empty, finished stream.
    /// </summary>
    public AsyncStream<TemperatureSeries> Series(SessionKey session)
    {
        long? found;
        try
        {
            found = RowIdFor(session);
        }
        catch (Exception)
        {
            found = null;
        }
        if (found is not { } id)
        {
            return AsyncStream<TemperatureSeries>.Finished();
        }
        if (_seriesBroadcasters.TryGetValue(id, out var existing))
        {
            return existing.Stream();
        }
        var b = new Broadcaster<TemperatureSeries>(replayLatest: true);
        _seriesBroadcasters[id] = b;
        if (TryBuildSeries(id) is { } s)
        {
            b.Send(s);
        }
        return b.Stream();
    }

    public void Rename(SessionKey session, string? nickname)
    {
        if (RowIdFor(session) is not { } id)
        {
            return;
        }
        _db.Run("UPDATE session SET nickname=? WHERE id=?", nickname, id);
    }

    public void Delete(SessionKey session)
    {
        if (RowIdFor(session) is not { } id)
        {
            return;
        }
        _db.Transaction(() =>
        {
            _db.Run("DELETE FROM sample WHERE session=?", id);
            _db.Run("DELETE FROM session WHERE id=?", id);
        });
        foreach (var (serial, rt) in _runtime.ToList())
        {
            if (rt.RowId == id)
            {
                _runtime[serial] = rt with { RowId = null };
            }
        }
        _lastRanges.Remove(id);
        if (_seriesBroadcasters.Remove(id, out var b))
        {
            b.Finish();
        }
    }

    /// <summary>
    /// Scrub readout at <paramref name="time"/>: core, surface, ambient (linearly interpolated between stored neighbours
    /// at most <see cref="MaxInterpolationGap"/> seqs apart, else the nearest sample) and the nearest sample's
    /// prediction. Null if the session has no samples or <paramref name="time"/> is more than half a period outside them.
    /// </summary>
    public SessionValue? ValueAt(SessionKey session, DateTimeOffset time)
    {
        if (LoadRow(RowIdFor(session) ?? -1) is not { } r)
        {
            return null;
        }
        var period = r.SamplePeriodMs / 1000.0;
        var anchorTime = Time.FromMs(r.AnchorTime);
        var pos = TimeDerivation.SeqAt(time, r.AnchorSeq, anchorTime, period);
        var fl = (long)Math.Floor(pos);
        var ce = (long)Math.Ceiling(pos);
        var lowerRows = _db.Query($"SELECT {SampleColumns} FROM sample WHERE session=? AND seq<=? ORDER BY seq DESC LIMIT 1", r.Id, fl);
        var upperRows = _db.Query($"SELECT {SampleColumns} FROM sample WHERE session=? AND seq>=? ORDER BY seq ASC LIMIT 1", r.Id, ce);
        var lower = lowerRows.Count > 0 ? DecodeSample(lowerRows[0], r) : null;
        var upper = upperRows.Count > 0 ? DecodeSample(upperRows[0], r) : null;
        // Swift min(by:): the first of equally near candidates (lower) wins.
        TemperatureSample? near = null;
        foreach (var c in new[] { lower, upper })
        {
            if (c is not null && (near is null || Math.Abs((double)c.Seq - pos) < Math.Abs((double)near.Seq - pos)))
            {
                near = c;
            }
        }
        if (near is null)
        {
            return null;
        }
        if (!(Math.Abs((double)near.Seq - pos) <= 0.5 || (lower is not null && upper is not null)))
        {
            return null;
        }
        if (lower is { } a && upper is { } b && a.Seq != b.Seq && b.Seq - a.Seq <= MaxInterpolationGap)
        {
            var f = Math.Min(1, Math.Max(0, (pos - a.Seq) / ((double)b.Seq - a.Seq)));
            return new SessionValue(time, near.Seq,
                a.Core + (b.Core - a.Core) * f, a.Surface + (b.Surface - a.Surface) * f,
                a.Ambient + (b.Ambient - a.Ambient) * f, near.Prediction);
        }
        return new SessionValue(time, near.Seq, near.Core, near.Surface, near.Ambient, near.Prediction);
    }

    // Internals

    private void PublishSeries(long rowId)
    {
        if (!_seriesBroadcasters.TryGetValue(rowId, out var b) || TryBuildSeries(rowId) is not { } s)
        {
            return;
        }
        b.Send(s);
    }

    private TemperatureSeries? TryBuildSeries(long rowId)
    {
        try
        {
            return BuildSeries(rowId);
        }
        catch (Exception)
        {
            return null; // Swift: try?
        }
    }

    private TemperatureSeries? BuildSeries(long rowId)
    {
        if (LoadRow(rowId) is not { } r)
        {
            return null;
        }
        return new TemperatureSeries(r.Key, r.SamplePeriodMs / 1000.0, r.AnchorSeq, Time.FromMs(r.AnchorTime), LoadSamples(rowId, r));
    }

    private List<TemperatureSample> LoadSamples(long rowId) =>
        LoadRow(rowId) is { } r ? LoadSamples(rowId, r) : [];

    private List<TemperatureSample> LoadSamples(long rowId, SessionRow r) =>
        _db.Query($"SELECT {SampleColumns} FROM sample WHERE session=? ORDER BY seq", rowId)
            .Select(row => DecodeSample(row, r))
            .OfType<TemperatureSample>()
            .ToList();

    private SessionRow? LoadRow(long id)
    {
        var rows = _db.Query($"SELECT {SessionRow.Columns} FROM session WHERE id=?", id);
        return rows.Count > 0 ? SessionRow.From(rows[0]) : null;
    }

    private long? RowIdFor(SessionKey key)
    {
        var rows = _db.Query("SELECT id FROM session WHERE serial=? AND session_id=? AND started_at=?",
            (long)key.Serial.Raw, (long)key.SessionId, key.StartedAtMs);
        return rows.Count > 0 ? rows[0].Int64(0) : null;
    }

    private static bool IsPredictive(PredictionMode mode) => mode is not (PredictionMode.None or PredictionMode.Reserved);

    internal const string CoreExpr =
        "CASE (vs & 7) WHEN 1 THEN t2 WHEN 2 THEN t3 WHEN 3 THEN t4 WHEN 4 THEN t5 WHEN 5 THEN t6 ELSE t1 END";

    internal const string SampleColumns = "seq,t1,t2,t3,t4,t5,t6,t7,t8,vs,pred_state,pred_mode,pred_type,setpoint,pred_seconds,est_core";

    private static TemperatureSample? DecodeSample(object?[] c, SessionRow r)
    {
        long I(int k) => c[k] is long v ? v : 0;
        double D(int k) => c[k] switch
        {
            double v => v,
            long v => v,
            _ => 0,
        };
        var bits = I(9);
        var core = (SensorIndex)(bits & 7);
        VirtualSensors vs;
        try
        {
            vs = new VirtualSensors(
                core <= SensorIndex.T6 ? core : SensorIndex.T1,
                (SensorIndex)(((bits >> 3) & 3) + 3),
                (SensorIndex)(((bits >> 5) & 3) + 4));
        }
        catch (CodecException)
        {
            return null;
        }
        var seq = (uint)I(0);
        var prediction = new PredictionLog(
            vs, StateFrom((int)I(10)),
            ModeFrom(I(11)), TypeFrom(I(12)),
            D(13), (uint)I(14), D(15));
        return new TemperatureSample(
            seq,
            TimeDerivation.TimeOf(seq, r.AnchorSeq, Time.FromMs(r.AnchorTime), r.SamplePeriodMs / 1000.0),
            Enumerable.Range(1, 8).Select(D).ToArray(), vs, prediction);
    }

    // Swift PredictionMode(rawValue:) ?? .none: unknown raw values read as None.
    private static PredictionMode ModeFrom(long raw) => raw is >= 0 and <= 3 ? (PredictionMode)raw : PredictionMode.None;

    private static PredictionType TypeFrom(long raw) => raw is >= 0 and <= 3 ? (PredictionType)raw : PredictionType.None;

    internal static int StateCode(PredictionState s) => s switch
    {
        PredictionState.NotInserted => 0,
        PredictionState.Inserted => 1,
        PredictionState.Warming => 2,
        PredictionState.Predicting => 3,
        PredictionState.RemovalPredictionDone => 4,
        _ => 15,
    };

    internal static PredictionState StateFrom(int n) => n switch
    {
        0 => PredictionState.NotInserted,
        1 => PredictionState.Inserted,
        2 => PredictionState.Warming,
        3 => PredictionState.Predicting,
        4 => PredictionState.RemovalPredictionDone,
        _ => PredictionState.Unknown,
    };

    /// <summary>The <c>session.kind</c> column: Swift <c>SessionKind.rawValue</c>.</summary>
    internal static string KindText(SessionKind kind) => kind == SessionKind.Predictive ? "predictive" : "manual";

    internal static SessionKind KindFrom(string? text) => text == "predictive" ? SessionKind.Predictive : SessionKind.Manual;

    private sealed record SessionRow(
        long Id, ProbeSerial Serial, uint SessionId, long SamplePeriodMs, long StartedAt, long? EndedAt,
        uint AnchorSeq, long AnchorTime, string? Nickname, SessionKind Kind, long? ReadySince, byte[]? Thumbnail)
    {
        public const string Columns = "id,serial,session_id,sample_period_ms,started_at,ended_at,anchor_seq,anchor_time,nickname,kind,ready_since,thumbnail";

        public SessionKey Key => new(Serial, SessionId, StartedAt);

        public static SessionRow? From(object?[] c)
        {
            long? I(int k) => c[k] as long?;
            if (I(0) is not { } id || I(1) is not { } serial || I(2) is not { } sid || I(4) is not { } started)
            {
                return null;
            }
            var period = I(3) ?? DefaultSamplePeriodMs;
            return new SessionRow(
                id, new ProbeSerial((uint)serial), (uint)sid, period > 0 ? period : DefaultSamplePeriodMs, started, I(5),
                (uint)(I(6) ?? 0), I(7) ?? started, c[8] as string, c[9] is string k ? KindFrom(k) : SessionKind.Manual,
                I(10), c[11] as byte[]);
        }
    }

    // IFollowedProbePersistence

    public Task<IReadOnlySet<ProbeSerial>> LoadFollowedAsync()
    {
        var rows = _db.Query("SELECT serial FROM probe WHERE followed=1");
        IReadOnlySet<ProbeSerial> set = rows.Where(r => r[0] is long).Select(r => new ProbeSerial((uint)(long)r[0]!)).ToHashSet();
        return Task.FromResult(set);
    }

    public Task SetFollowedAsync(ProbeSerial serial, bool followed)
    {
        _db.Run("""
            INSERT INTO probe(serial, followed) VALUES(?,?)
            ON CONFLICT(serial) DO UPDATE SET followed=excluded.followed
            """, (long)serial.Raw, followed ? 1L : 0L);
        return Task.CompletedTask;
    }
}

/// <param name="Requested">Records asked for.</param>
/// <param name="Received">New records stored.</param>
/// <param name="Remaining">Seqs in the log range still missing afterwards.</param>
/// <param name="Failed">A fetch threw (link lost) or the backfill was cancelled; the rest was not attempted.</param>
public sealed record BackfillResult(int Requested, int Received, int Remaining, bool Failed);
