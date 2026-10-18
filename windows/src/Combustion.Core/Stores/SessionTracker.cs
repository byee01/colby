using Combustion.Codec;

namespace Combustion.Core;

/// <summary>
/// Detects the start of a new cook from successive full statuses of one probe. docs/02 §6.2. Pure.
/// <para>Rules:</para>
/// <list type="number">
/// <item>First status ever seen: new session (<see cref="Reason.Initial"/>).</item>
/// <item><c>sessionId</c> non-zero and different from the current non-zero id: new session.</item>
/// <item>Otherwise, when the id is 0 on either side (old firmware or node), fallback rules:
/// <c>logRange.Max</c> is lower than the previous max: new session;
/// the probe was missing for more than <see cref="GapThreshold"/> (10 min) and returns with <c>logRange.Min</c>
/// lower than before (log reset): new session.</item>
/// <item>Current id is 0 and a non-zero id appears (and no fallback rule fires): same session, id adopted.</item>
/// </list>
/// Limitation: after a long gap with identical <c>Min</c> (e.g. 0 both times) and a higher max, the session
/// is treated as continuing; only a session id or a max/min regression can tell cooks apart.
/// <para>Swift value type: copy with <c>with { }</c> before observing when the old state must survive.</para>
/// </summary>
public sealed record SessionTracker
{
    public enum Reason { Initial, SessionIdChanged, LogRangeRegressed, ReturnedAfterGap }

    public abstract record Decision
    {
        private Decision() { }

        public sealed record NewSession(Reason Reason) : Decision;

        public sealed record Continuing : Decision;

        /// <summary>Same session, but its id (previously unknown, 0) is now known.</summary>
        public sealed record AdoptedSessionId(uint SessionId) : Decision;
    }

    /// <summary>Seconds.</summary>
    public const double DefaultGapThreshold = 600;

    /// <param name="gapThreshold">Seconds.</param>
    public SessionTracker(double gapThreshold = DefaultGapThreshold)
    {
        GapThreshold = gapThreshold;
    }

    /// <summary>Continue a session loaded from storage.</summary>
    public SessionTracker(uint restoring, LogRange logRange, DateTimeOffset lastSeen, double gapThreshold = DefaultGapThreshold)
    {
        GapThreshold = gapThreshold;
        CurrentSessionId = restoring;
        LastRange = logRange;
        LastSeen = lastSeen;
    }

    /// <summary>Seconds.</summary>
    public double GapThreshold { get; }

    /// <summary>Null before the first observation; 0 when the id is unknown.</summary>
    public uint? CurrentSessionId { get; private set; }

    public LogRange? LastRange { get; private set; }

    public DateTimeOffset? LastSeen { get; private set; }

    /// <param name="sessionId">0 when the status carried none.</param>
    public Decision Observe(uint sessionId, LogRange logRange, DateTimeOffset at)
    {
        try
        {
            return Decide(sessionId, logRange, at);
        }
        finally
        {
            LastRange = logRange;
            LastSeen = at;
        }
    }

    private Decision Decide(uint sessionId, LogRange logRange, DateTimeOffset at)
    {
        if (CurrentSessionId is not { } current)
        {
            CurrentSessionId = sessionId;
            return new Decision.NewSession(Reason.Initial);
        }
        if (sessionId != 0 && current != 0 && sessionId != current)
        {
            CurrentSessionId = sessionId;
            return new Decision.NewSession(Reason.SessionIdChanged);
        }
        if (sessionId == 0 || current == 0)
        {
            if (FallbackReason(logRange, at) is { } reason)
            {
                CurrentSessionId = sessionId;
                return new Decision.NewSession(reason);
            }
        }
        if (current == 0 && sessionId != 0)
        {
            CurrentSessionId = sessionId;
            return new Decision.AdoptedSessionId(sessionId);
        }
        return new Decision.Continuing();
    }

    private Reason? FallbackReason(LogRange range, DateTimeOffset at)
    {
        if (LastRange is not { } last)
        {
            return null;
        }
        if (range.Max < last.Max)
        {
            return Reason.LogRangeRegressed;
        }
        if (LastSeen is { } seen && at.Since(seen) > GapThreshold && range.Min < last.Min)
        {
            return Reason.ReturnedAfterGap;
        }
        return null;
    }
}
