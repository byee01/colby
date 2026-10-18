using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Combustion.Core.Tests;

public class TraceSinkTests
{
    private static Dictionary<string, TraceValue> F(params (string, TraceValue)[] kv) => kv.ToDictionary(p => p.Item1, p => p.Item2);

    [Fact]
    public void FormatsKeysSortedFloatsRoundedSerialUppercaseHex() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var sink = new JsonlTraceSink(clock);
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(12500));
        sink.Emit("probe", F(("serial", new TraceValue.Serial(0x10005A3F)), ("core", 54.3456), ("state", "predicting")));
        Assert.Equal(["""{"core":54.35,"kind":"probe","serial":"10005A3F","state":"predicting","t":12.5}"""], sink.Lines);
    });

    [Fact]
    public void TimeIsRelativeToSinkCreation() => Det.Run(async () =>
    {
        var clock = new TestClock();
        await clock.AdvanceAsync(TimeSpan.FromSeconds(100));
        var sink = new JsonlTraceSink(clock);
        await clock.AdvanceAsync(TimeSpan.FromSeconds(61));
        sink.Emit("alert", F(("rule", "r1"), ("transition", "idle->firing"), ("value", 57.1)));
        Assert.Equal(["""{"kind":"alert","rule":"r1","t":61,"transition":"idle->firing","value":57.1}"""], sink.Lines);
    });

    [Theory]
    [InlineData(1815, "1815")]
    [InlineData(57.10, "57.1")]
    [InlineData(0.004, "0")]
    [InlineData(-0.001, "0")]
    [InlineData(-3.456, "-3.46")]
    [InlineData(99.999, "100")]
    [InlineData(double.NaN, "null")]
    [InlineData(double.PositiveInfinity, "null")]
    public void NumberFormatting(double d, string expected) => Assert.Equal(expected, JsonlTraceSink.Number(d, 2));

    [Fact]
    public void ThreeDecimalTime() => Assert.Equal("0.083", JsonlTraceSink.Number(0.0834, 3));

    [Fact]
    public void SerialsArePaddedToEightDigits()
    {
        var sink = new JsonlTraceSink(new TestClock());
        sink.Emit("probe", F(("serial", new TraceValue.Serial(0xABC))));
        Assert.Contains("\"serial\":\"00000ABC\"", sink.Lines[0]);
    }

    [Fact]
    public void AllValueTypesAndEscaping()
    {
        var sink = new JsonlTraceSink(new TestClock());
        sink.Emit("x", F(("b", true), ("i", -4), ("n", TraceValue.None), ("s", "a\"b\\c\nd\u0001")));
        Assert.Equal(["""{"b":true,"i":-4,"kind":"x","n":null,"s":"a\"b\\c\nd\u0001","t":0}"""], sink.Lines);
        using var doc = JsonDocument.Parse(sink.Lines[0]);
        Assert.Equal("a\"b\\c\nd\u0001", doc.RootElement.GetProperty("s").GetString());
    }

    [Fact]
    public void WritesOneLinePerEventToFile() => Det.Run(async () =>
    {
        var path = Path.Combine(Path.GetTempPath(), $"trace-{Guid.NewGuid()}.jsonl");
        try
        {
            var clock = new TestClock();
            using (var sink = new JsonlTraceSink(clock, path))
            {
                sink.Emit("a", F());
                await clock.AdvanceAsync(TimeSpan.FromSeconds(1));
                sink.Emit("b", F());
            }
            Assert.Equal("{\"kind\":\"a\",\"t\":0}\n{\"kind\":\"b\",\"t\":1}\n", File.ReadAllText(path));
        }
        finally
        {
            File.Delete(path);
        }
    });

    [Fact]
    public void HexStringRoundTrip()
    {
        Assert.Equal("CAFE000F", HexString.Encode([0xCA, 0xFE, 0x00, 0x0F]));
        Assert.Equal([0xCA, 0xFE, 0x00, 0x0F], HexString.Decode("cafe000F"));
        Assert.Null(HexString.Decode("abc"));
        Assert.Null(HexString.Decode("zz"));
        Assert.Equal([], HexString.Decode("")!);
    }
}

public class PersistenceTests
{
    private static readonly int Current = Schema.Migrations.Max(m => m.Version);

    private static SqliteDatabase Migrated()
    {
        var db = SqliteDatabase.InMemory();
        Schema.Migrate(db);
        return db;
    }

    [Fact]
    public void MigrationsRunOnceAndSetUserVersion()
    {
        using var db = SqliteDatabase.InMemory();
        Assert.Equal(0, db.UserVersion);
        Schema.Migrate(db);
        Assert.Equal(Current, db.UserVersion);
        Schema.Migrate(db);
        Assert.Equal(Current, db.UserVersion);
        var tables = db.Query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").Select(r => r.Text(0));
        Assert.Equal(["alert_event", "alert_rule", "alert_rule_set", "probe", "sample", "session"], tables);
    }

    [Fact]
    public void LaterMigrationsApplyInOrderOnce()
    {
        using var db = Migrated();
        var extra = new Migration(Current + 1, "ALTER TABLE probe ADD COLUMN note TEXT");
        db.Migrate([.. Schema.Migrations, extra]);
        db.Migrate([.. Schema.Migrations, extra]);
        Assert.Equal(Current + 1, db.UserVersion);
    }

    [Fact]
    public void FailedMigrationRollsBack()
    {
        using var db = Migrated();
        var bad = new Migration(Current + 1, "CREATE TABLE ok(x); CREATE TABLE probe(y)");
        Assert.Throws<SqliteException>(() => db.Migrate([.. Schema.Migrations, bad]));
        Assert.Equal(Current, db.UserVersion);
        Assert.Empty(db.Query("SELECT name FROM sqlite_master WHERE name='ok'"));
    }

    [Fact]
    public void SchemaMatchesDesignDoc()
    {
        using var db = Migrated();
        List<string?> Columns(string table) => db.Query($"SELECT name FROM pragma_table_info('{table}')").Select(r => r.Text(0)).ToList();
        Assert.Equal(["serial", "nickname", "followed", "last_seen"], Columns("probe"));
        Assert.Equal(["id", "serial", "session_id", "sample_period_ms", "started_at", "ended_at",
            "anchor_seq", "anchor_time", "nickname", "kind", "ready_since", "thumbnail"], Columns("session"));
        Assert.Equal(["session", "seq", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "vs",
            "pred_state", "pred_mode", "pred_type", "setpoint", "pred_seconds", "est_core"], Columns("sample"));
        Assert.Equal(["id", "serial", "kind", "params_json", "enabled", "position"], Columns("alert_rule"));
        Assert.Equal(["serial"], Columns("alert_rule_set"));
        Assert.Equal(["id", "rule_id", "serial", "session", "fired_at", "cleared_at", "acked_at", "value"], Columns("alert_event"));
    }

    [Fact]
    public void SampleInsertOrIgnoreIsIdempotentOnPrimaryKey()
    {
        using var db = Migrated();
        const string sql = "INSERT OR IGNORE INTO sample(session, seq, t1, vs) VALUES (?, ?, ?, ?)";
        Assert.Equal(1, db.Run(sql, 1L, 7L, 21.5, 3L));
        Assert.Equal(0, db.Run(sql, 1L, 7L, 99.0, 9L));
        Assert.Equal(1, db.Run(sql, 1L, 8L, 22.0, 3L));
        var rows = db.Query("SELECT seq, t1 FROM sample ORDER BY seq");
        Assert.Equal([(7L, 21.5), (8L, 22.0)], rows.Select(r => (r.Int64(0)!.Value, r.Double(1)!.Value)));
    }

    [Fact]
    public void SessionUniqueKey()
    {
        using var db = Migrated();
        const string sql = "INSERT INTO session(serial, session_id, started_at) VALUES (?, ?, ?)";
        db.Run(sql, 0x10005A3FL, 0L, 1000L);
        db.Run(sql, 0x10005A3FL, 0L, 2000L);
        var e = Assert.Throws<SqliteException>(() => db.Run(sql, 0x10005A3FL, 0L, 1000L));
        Assert.Equal(19, e.SqliteErrorCode);
    }

    [Fact]
    public void ValueRoundTripIncludingNullAndBlob()
    {
        using var db = Migrated();
        db.Run("INSERT INTO probe(serial, nickname, followed, last_seen) VALUES (?, ?, ?, ?)", (long)uint.MaxValue, "Brisket \U0001F525", null, -5L);
        db.Run("INSERT INTO session(id, thumbnail) VALUES (1, ?)", new byte[] { 0, 1, 2, 255 });
        db.Run("INSERT INTO session(id, thumbnail) VALUES (2, ?)", Array.Empty<byte>());
        var row = Assert.Single(db.Query("SELECT serial, nickname, followed, last_seen FROM probe"));
        Assert.Equal(uint.MaxValue, row.Int64(0));
        Assert.Equal("Brisket \U0001F525", row.Text(1));
        Assert.Null(row[2]);
        Assert.Equal(-5, row.Int64(3));
        var blobs = db.Query("SELECT thumbnail FROM session ORDER BY id");
        Assert.Equal([0, 1, 2, 255], blobs[0].Blob(0)!);
        Assert.Equal([], blobs[1].Blob(0) ?? []);
    }

    [Fact]
    public void PreparedStatementCanBeReused()
    {
        using var db = Migrated();
        db.Transaction(() =>
        {
            using var insert = db.Prepare("INSERT INTO sample(session, seq, est_core) VALUES (?, ?, ?)", 3);
            for (var seq = 0; seq < 3; seq++)
            {
                Assert.Equal(1, insert.Run(1L, (long)seq, seq / 2.0));
            }
        });
        Assert.Equal(3L, db.Query("SELECT count(*) FROM sample")[0].Int64(0));
    }

    private sealed class Boom : Exception;

    [Fact]
    public void TransactionsCommitRollbackAndNest()
    {
        using var db = Migrated();
        db.Transaction(() => db.Run("INSERT INTO probe(serial) VALUES (1)"));
        Assert.Throws<Boom>(() => db.Transaction(() =>
        {
            db.Run("INSERT INTO probe(serial) VALUES (2)");
            throw new Boom();
        }));
        db.Transaction(() =>
        {
            db.Run("INSERT INTO probe(serial) VALUES (3)");
            try
            {
                db.Transaction(() =>
                {
                    db.Run("INSERT INTO probe(serial) VALUES (4)");
                    throw new Boom();
                });
            }
            catch (Boom)
            {
            }
        });
        Assert.Equal([1L, 3L], db.Query("SELECT serial FROM probe ORDER BY serial").Select(r => r.Int64(0)!.Value));
    }

    [Fact]
    public void FileDatabasePersistsAcrossReopen()
    {
        var path = Path.Combine(Path.GetTempPath(), $"colby-{Guid.NewGuid()}.sqlite");
        try
        {
            using (var db = new SqliteDatabase(path))
            {
                Schema.Migrate(db);
                db.Run("INSERT INTO probe(serial, nickname) VALUES (5, 'x')");
            }
            using (var db = new SqliteDatabase(path))
            {
                Schema.Migrate(db);
                Assert.Equal(Current, db.UserVersion);
                Assert.Equal("x", db.Query("SELECT nickname FROM probe")[0].Text(0));
            }
        }
        finally
        {
            foreach (var ext in new[] { "", "-wal", "-shm" })
            {
                File.Delete(path + ext);
            }
        }
    }

    [Fact]
    public void BadSqlThrowsWithMessage()
    {
        using var db = SqliteDatabase.InMemory();
        var e = Assert.Throws<SqliteException>(() => db.Exec("SELEC nonsense"));
        Assert.Equal(1, e.SqliteErrorCode);
        Assert.Contains("syntax", e.Message);
    }

    [Fact]
    public void QuestionMarksInsideLiteralsAreKept() =>
        Assert.Equal("SELECT '?', $1 WHERE x = $2", SqliteDatabase.Numbered("SELECT '?', ? WHERE x = ?"));
}
