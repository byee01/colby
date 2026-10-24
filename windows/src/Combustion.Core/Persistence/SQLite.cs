using Microsoft.Data.Sqlite;

namespace Combustion.Core;

/// <summary>
/// Thin wrapper over a <see cref="SqliteConnection"/> with the same surface as the Swift <c>SQLiteDatabase</c>.
/// Values are <c>null</c>, <see cref="long"/>, <see cref="double"/>, <see cref="string"/> or <c>byte[]</c>.
/// Not thread-safe: owned by one store on the core context.
/// </summary>
public sealed class SqliteDatabase : IDisposable
{
    private static int s_memoryCounter;
    private readonly SqliteConnection _connection;
    private SqliteTransaction? _transaction;
    private int _transactionDepth;

    /// <summary><c>":memory:"</c> or a file path.</summary>
    public SqliteDatabase(string path)
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = path == ":memory:" ? $"colby-mem-{Interlocked.Increment(ref s_memoryCounter)}" : path,
            Mode = path == ":memory:" ? SqliteOpenMode.Memory : SqliteOpenMode.ReadWriteCreate,
            Cache = path == ":memory:" ? SqliteCacheMode.Private : SqliteCacheMode.Default,
            Pooling = false,
            // History and the alert store each hold a connection to the same file. Microsoft.Data.Sqlite retries a
            // command that meets the other's lock (SQLITE_BUSY) for this long; 5 s as on the Mac (sqlite3_busy_timeout).
            DefaultTimeout = 5,
        };
        _connection = new SqliteConnection(builder.ToString());
        _connection.Open();
        if (path != ":memory:")
        {
            Query("PRAGMA journal_mode=WAL");
        }
    }

    public static SqliteDatabase InMemory() => new(":memory:");

    public void Dispose() => _connection.Dispose();

    private SqliteCommand Command(string sql, IReadOnlyList<object?>? parameters)
    {
        var cmd = _connection.CreateCommand();
        cmd.CommandText = sql;
        cmd.Transaction = _transaction;
        if (parameters is not null)
        {
            for (var i = 0; i < parameters.Count; i++)
            {
                cmd.Parameters.AddWithValue("$" + (i + 1), parameters[i] ?? DBNull.Value);
            }
        }
        return cmd;
    }

    /// <summary>Run one or more statements without parameters or results.</summary>
    public void Exec(string sql)
    {
        using var cmd = Command(sql, null);
        cmd.ExecuteNonQuery();
    }

    /// <summary>Prepare, bind (<c>?</c> placeholders are rewritten to <c>$1</c>, <c>$2</c>, ...), run. Returns rows changed.</summary>
    public int Run(string sql, params object?[] parameters)
    {
        using var cmd = Command(Numbered(sql), parameters);
        return cmd.ExecuteNonQuery();
    }

    public List<object?[]> Query(string sql, params object?[] parameters)
    {
        using var cmd = Command(Numbered(sql), parameters);
        using var reader = cmd.ExecuteReader();
        var rows = new List<object?[]>();
        while (reader.Read())
        {
            var row = new object?[reader.FieldCount];
            for (var i = 0; i < row.Length; i++)
            {
                row[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            }
            rows.Add(row);
        }
        return rows;
    }

    /// <summary>A compiled statement to run many times with different parameters (inside a <see cref="Transaction{T}"/> for speed).</summary>
    public PreparedStatement Prepare(string sql, int parameterCount)
    {
        var cmd = Command(Numbered(sql), null);
        for (var i = 0; i < parameterCount; i++)
        {
            cmd.Parameters.Add(new SqliteParameter("$" + (i + 1), null));
        }
        cmd.Prepare();
        return new PreparedStatement(cmd, this);
    }

    internal SqliteTransaction? CurrentTransaction => _transaction;

    public long LastInsertRowId => (long)Query("SELECT last_insert_rowid()")[0][0]!;

    /// <summary>Runs <paramref name="body"/> in a transaction (a savepoint when nested). Rolls back if it throws.</summary>
    public T Transaction<T>(Func<T> body)
    {
        var nested = _transactionDepth > 0;
        var name = "sp" + _transactionDepth;
        if (nested)
        {
            Exec($"SAVEPOINT {name}");
        }
        else
        {
            _transaction = _connection.BeginTransaction(deferred: false);
        }
        _transactionDepth++;
        try
        {
            var result = body();
            if (nested)
            {
                Exec($"RELEASE {name}");
            }
            else
            {
                _transaction!.Commit();
            }
            return result;
        }
        catch
        {
            try
            {
                if (nested)
                {
                    Exec($"ROLLBACK TO {name}; RELEASE {name}");
                }
                else
                {
                    _transaction?.Rollback();
                }
            }
            catch (SqliteException)
            {
            }
            throw;
        }
        finally
        {
            _transactionDepth--;
            if (!nested)
            {
                _transaction?.Dispose();
                _transaction = null;
            }
        }
    }

    public void Transaction(Action body) => Transaction(() =>
    {
        body();
        return 0;
    });

    public int UserVersion
    {
        get => Convert.ToInt32(Query("PRAGMA user_version")[0][0], System.Globalization.CultureInfo.InvariantCulture);
        set => Exec($"PRAGMA user_version = {value}");
    }

    /// <summary>Applies, in order and each in its own transaction, every migration whose version is greater than
    /// <c>user_version</c>, then records the new version.</summary>
    public void Migrate(IEnumerable<Migration> migrations)
    {
        foreach (var m in migrations.OrderBy(m => m.Version))
        {
            if (m.Version <= UserVersion)
            {
                continue;
            }
            Transaction(() =>
            {
                Exec(m.Sql);
                Exec($"PRAGMA user_version = {m.Version}");
            });
        }
    }

    /// <summary>Rewrites positional <c>?</c> to <c>$n</c> outside string literals.</summary>
    internal static string Numbered(string sql)
    {
        if (!sql.Contains('?'))
        {
            return sql;
        }
        var sb = new System.Text.StringBuilder(sql.Length + 8);
        var n = 0;
        var inString = false;
        foreach (var c in sql)
        {
            if (c == '\'')
            {
                inString = !inString;
            }
            if (c == '?' && !inString)
            {
                sb.Append('$').Append(++n);
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }
}

public sealed record Migration(int Version, string Sql);

public sealed class PreparedStatement : IDisposable
{
    private readonly SqliteCommand _command;
    private readonly SqliteDatabase _db;

    internal PreparedStatement(SqliteCommand command, SqliteDatabase db)
    {
        _command = command;
        _db = db;
    }

    /// <summary>Binds <paramref name="parameters"/> and runs to completion. Returns rows changed.</summary>
    public int Run(params object?[] parameters)
    {
        Bind(parameters);
        return _command.ExecuteNonQuery();
    }

    public List<object?[]> Query(params object?[] parameters)
    {
        Bind(parameters);
        using var reader = _command.ExecuteReader();
        var rows = new List<object?[]>();
        while (reader.Read())
        {
            var row = new object?[reader.FieldCount];
            for (var i = 0; i < row.Length; i++)
            {
                row[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            }
            rows.Add(row);
        }
        return rows;
    }

    private void Bind(object?[] parameters)
    {
        _command.Transaction = _db.CurrentTransaction;
        for (var i = 0; i < parameters.Length; i++)
        {
            _command.Parameters[i].Value = parameters[i] ?? DBNull.Value;
        }
    }

    public void Dispose() => _command.Dispose();
}

/// <summary>Column readers for <see cref="SqliteDatabase.Query"/> rows.</summary>
public static class SqliteRow
{
    public static long? Int64(this object?[] row, int i) => row[i] is null ? null : Convert.ToInt64(row[i], System.Globalization.CultureInfo.InvariantCulture);
    public static double? Double(this object?[] row, int i) => row[i] is null ? null : Convert.ToDouble(row[i], System.Globalization.CultureInfo.InvariantCulture);
    public static string? Text(this object?[] row, int i) => row[i] as string;
    public static byte[]? Blob(this object?[] row, int i) => row[i] as byte[];
}
