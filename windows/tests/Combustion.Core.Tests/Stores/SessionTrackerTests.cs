namespace Combustion.Core.Tests;

using D = SessionTracker.Decision;
using R = SessionTracker.Reason;

public class SessionTrackerTests
{
    private static readonly DateTimeOffset T0 = StoreFixtures.T0;

    private static LogRange Rg(uint min, uint max) => new(min, max);

    private static D New(R reason) => new D.NewSession(reason);

    private static readonly D Continuing = new D.Continuing();

    [Fact]
    public void FirstStatusStartsSession()
    {
        var t = new SessionTracker();
        Assert.Equal(New(R.Initial), t.Observe(7, Rg(0, 3), T0));
        Assert.Equal(7u, t.CurrentSessionId);
        var u = new SessionTracker();
        Assert.Equal(New(R.Initial), u.Observe(0, Rg(0, 3), T0));
    }

    [Fact]
    public void SameSessionIdContinues()
    {
        var t = new SessionTracker();
        t.Observe(7, Rg(0, 3), T0);
        Assert.Equal(Continuing, t.Observe(7, Rg(0, 4), T0.AddSeconds(5)));
    }

    [Fact]
    public void DifferentNonZeroIdStartsNewSession()
    {
        var t = new SessionTracker();
        t.Observe(7, Rg(0, 300), T0);
        Assert.Equal(New(R.SessionIdChanged), t.Observe(8, Rg(0, 301), T0.AddSeconds(5)));
        Assert.Equal(8u, t.CurrentSessionId);
    }

    [Fact]
    public void IdChangeWinsEvenAfterLongGapOrRegression()
    {
        var t = new SessionTracker();
        t.Observe(7, Rg(0, 300), T0);
        Assert.Equal(New(R.SessionIdChanged), t.Observe(8, Rg(0, 2), T0.AddSeconds(3600)));
    }

    [Fact]
    public void SameIdIgnoresFallbackRules()
    {
        var t = new SessionTracker();
        t.Observe(7, Rg(0, 300), T0);
        // max went down and long gap, but id says it is the same cook.
        Assert.Equal(Continuing, t.Observe(7, Rg(0, 10), T0.AddSeconds(3600)));
    }

    [Fact]
    public void ZeroIdMaxDecreaseStartsNewSession()
    {
        var t = new SessionTracker();
        t.Observe(0, Rg(0, 100), T0);
        Assert.Equal(Continuing, t.Observe(0, Rg(0, 101), T0.AddSeconds(5)));
        Assert.Equal(New(R.LogRangeRegressed), t.Observe(0, Rg(0, 100), T0.AddSeconds(10)));
        Assert.Equal(Continuing, t.Observe(0, Rg(0, 101), T0.AddSeconds(15))); // baseline reset
    }

    [Fact]
    public void ZeroIdMaxEqualContinues()
    {
        var t = new SessionTracker();
        t.Observe(0, Rg(0, 100), T0);
        Assert.Equal(Continuing, t.Observe(0, Rg(0, 100), T0.AddSeconds(1)));
    }

    [Fact]
    public void ZeroIdGapOverTenMinutesWithMinResetStartsNewSession()
    {
        var t = new SessionTracker();
        t.Observe(0, Rg(40, 500), T0);
        Assert.Equal(New(R.ReturnedAfterGap), t.Observe(0, Rg(0, 600), T0.AddSeconds(601)));
    }

    [Fact]
    public void ZeroIdGapExactlyTenMinutesIsNotAGap()
    {
        var t = new SessionTracker();
        t.Observe(0, Rg(40, 500), T0);
        Assert.Equal(Continuing, t.Observe(0, Rg(0, 600), T0.AddSeconds(600)));
    }

    [Fact]
    public void ZeroIdGapWithoutMinResetContinues()
    {
        var t = new SessionTracker();
        t.Observe(0, Rg(40, 500), T0);
        Assert.Equal(Continuing, t.Observe(0, Rg(40, 700), T0.AddSeconds(3600)));
        var u = new SessionTracker();
        u.Observe(0, Rg(40, 500), T0);
        Assert.Equal(Continuing, u.Observe(0, Rg(55, 700), T0.AddSeconds(3600))); // min grew: log wrapped
    }

    [Fact]
    public void MinResetWithoutGapContinues()
    {
        var t = new SessionTracker();
        t.Observe(0, Rg(40, 500), T0);
        Assert.Equal(Continuing, t.Observe(0, Rg(0, 600), T0.AddSeconds(60)));
    }

    [Fact]
    public void GapRuleUsesLastSeenNotFirstSeen()
    {
        var t = new SessionTracker();
        t.Observe(0, Rg(10, 500), T0);
        for (var i = 1; i <= 5; i++)
        {
            t.Observe(0, Rg(10, 500 + (uint)i), T0.AddSeconds(i * 300));
        }
        // 300 s since last status: no gap even though 25 min since the first.
        Assert.Equal(Continuing, t.Observe(0, Rg(0, 510), T0.AddSeconds(1800)));
    }

    [Fact]
    public void UnknownIdBecomesKnownIsSameSession()
    {
        var t = new SessionTracker();
        t.Observe(0, Rg(0, 10), T0);
        Assert.Equal(new D.AdoptedSessionId(5), t.Observe(5, Rg(0, 11), T0.AddSeconds(5)));
        Assert.Equal(5u, t.CurrentSessionId);
        Assert.Equal(Continuing, t.Observe(5, Rg(0, 12), T0.AddSeconds(10)));
    }

    [Fact]
    public void UnknownIdBecomingKnownWithRegressionIsNewSession()
    {
        var t = new SessionTracker();
        t.Observe(0, Rg(0, 100), T0);
        Assert.Equal(New(R.LogRangeRegressed), t.Observe(5, Rg(0, 3), T0.AddSeconds(5)));
        Assert.Equal(5u, t.CurrentSessionId);
    }

    [Fact]
    public void KnownSessionThenStatusWithoutIdKeepsSession()
    {
        // A legacy node relays the same cook without session fields.
        var t = new SessionTracker();
        t.Observe(5, Rg(0, 10), T0);
        Assert.Equal(Continuing, t.Observe(0, Rg(0, 11), T0.AddSeconds(5)));
        Assert.Equal(5u, t.CurrentSessionId);
        Assert.Equal(Continuing, t.Observe(5, Rg(0, 12), T0.AddSeconds(10)));
    }

    [Fact]
    public void RestoredTrackerContinuesOrSplits()
    {
        var t = new SessionTracker(restoring: 9, logRange: Rg(0, 50), lastSeen: T0);
        Assert.Equal(Continuing, t.Observe(9, Rg(0, 60), T0.AddSeconds(10)));
        var u = new SessionTracker(restoring: 9, logRange: Rg(0, 50), lastSeen: T0);
        Assert.Equal(New(R.SessionIdChanged), u.Observe(10, Rg(0, 1), T0.AddSeconds(10)));
    }

    [Fact]
    public void CustomGapThreshold()
    {
        var t = new SessionTracker(gapThreshold: 30);
        t.Observe(0, Rg(10, 50), T0);
        Assert.Equal(New(R.ReturnedAfterGap), t.Observe(0, Rg(0, 60), T0.AddSeconds(31)));
    }
}
