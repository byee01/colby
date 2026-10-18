import CombustionCodec
import CombustionCore
import Foundation
import Testing

struct SessionTrackerTests {
    private let t0 = StoreFixtures.t0
    private func r(_ min: UInt32, _ max: UInt32) -> LogRange { LogRange(min: min, max: max) }

    @Test func firstStatusStartsSession() {
        var t = SessionTracker()
        #expect(t.observe(sessionId: 7, logRange: r(0, 3), at: t0) == .newSession(.initial))
        #expect(t.currentSessionId == 7)
        var u = SessionTracker()
        #expect(u.observe(sessionId: 0, logRange: r(0, 3), at: t0) == .newSession(.initial))
    }

    @Test func sameSessionIdContinues() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 7, logRange: r(0, 3), at: t0)
        #expect(t.observe(sessionId: 7, logRange: r(0, 4), at: t0 + 5) == .continuing)
    }

    @Test func differentNonZeroIdStartsNewSession() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 7, logRange: r(0, 300), at: t0)
        #expect(t.observe(sessionId: 8, logRange: r(0, 301), at: t0 + 5) == .newSession(.sessionIdChanged))
        #expect(t.currentSessionId == 8)
    }

    @Test func idChangeWinsEvenAfterLongGapOrRegression() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 7, logRange: r(0, 300), at: t0)
        #expect(t.observe(sessionId: 8, logRange: r(0, 2), at: t0 + 3600) == .newSession(.sessionIdChanged))
    }

    @Test func sameIdIgnoresFallbackRules() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 7, logRange: r(0, 300), at: t0)
        // max went down and long gap, but id says it is the same cook.
        #expect(t.observe(sessionId: 7, logRange: r(0, 10), at: t0 + 3600) == .continuing)
    }

    @Test func zeroIdMaxDecreaseStartsNewSession() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 0, logRange: r(0, 100), at: t0)
        #expect(t.observe(sessionId: 0, logRange: r(0, 101), at: t0 + 5) == .continuing)
        #expect(t.observe(sessionId: 0, logRange: r(0, 100), at: t0 + 10) == .newSession(.logRangeRegressed))
        #expect(t.observe(sessionId: 0, logRange: r(0, 101), at: t0 + 15) == .continuing)   // baseline reset
    }

    @Test func zeroIdMaxEqualContinues() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 0, logRange: r(0, 100), at: t0)
        #expect(t.observe(sessionId: 0, logRange: r(0, 100), at: t0 + 1) == .continuing)
    }

    @Test func zeroIdGapOverTenMinutesWithMinResetStartsNewSession() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 0, logRange: r(40, 500), at: t0)
        #expect(t.observe(sessionId: 0, logRange: r(0, 600), at: t0 + 601) == .newSession(.returnedAfterGap))
    }

    @Test func zeroIdGapExactlyTenMinutesIsNotAGap() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 0, logRange: r(40, 500), at: t0)
        #expect(t.observe(sessionId: 0, logRange: r(0, 600), at: t0 + 600) == .continuing)
    }

    @Test func zeroIdGapWithoutMinResetContinues() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 0, logRange: r(40, 500), at: t0)
        #expect(t.observe(sessionId: 0, logRange: r(40, 700), at: t0 + 3600) == .continuing)
        var u = SessionTracker()
        _ = u.observe(sessionId: 0, logRange: r(40, 500), at: t0)
        #expect(u.observe(sessionId: 0, logRange: r(55, 700), at: t0 + 3600) == .continuing)   // min grew: log wrapped
    }

    @Test func minResetWithoutGapContinues() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 0, logRange: r(40, 500), at: t0)
        #expect(t.observe(sessionId: 0, logRange: r(0, 600), at: t0 + 60) == .continuing)
    }

    @Test func gapRuleUsesLastSeenNotFirstSeen() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 0, logRange: r(10, 500), at: t0)
        for i in 1...5 { _ = t.observe(sessionId: 0, logRange: r(10, 500 + UInt32(i)), at: t0 + Double(i) * 300) }
        // 300 s since last status: no gap even though 25 min since the first.
        #expect(t.observe(sessionId: 0, logRange: r(0, 510), at: t0 + 1800) == .continuing)
    }

    @Test func unknownIdBecomesKnownIsSameSession() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 0, logRange: r(0, 10), at: t0)
        #expect(t.observe(sessionId: 5, logRange: r(0, 11), at: t0 + 5) == .adoptedSessionId(5))
        #expect(t.currentSessionId == 5)
        #expect(t.observe(sessionId: 5, logRange: r(0, 12), at: t0 + 10) == .continuing)
    }

    @Test func unknownIdBecomingKnownWithRegressionIsNewSession() {
        var t = SessionTracker()
        _ = t.observe(sessionId: 0, logRange: r(0, 100), at: t0)
        #expect(t.observe(sessionId: 5, logRange: r(0, 3), at: t0 + 5) == .newSession(.logRangeRegressed))
        #expect(t.currentSessionId == 5)
    }

    @Test func knownSessionThenStatusWithoutIdKeepsSession() {
        // A legacy node relays the same cook without session fields.
        var t = SessionTracker()
        _ = t.observe(sessionId: 5, logRange: r(0, 10), at: t0)
        #expect(t.observe(sessionId: 0, logRange: r(0, 11), at: t0 + 5) == .continuing)
        #expect(t.currentSessionId == 5)
        #expect(t.observe(sessionId: 5, logRange: r(0, 12), at: t0 + 10) == .continuing)
    }

    @Test func restoredTrackerContinuesOrSplits() {
        var t = SessionTracker(restoring: 9, logRange: r(0, 50), lastSeen: t0)
        #expect(t.observe(sessionId: 9, logRange: r(0, 60), at: t0 + 10) == .continuing)
        var u = SessionTracker(restoring: 9, logRange: r(0, 50), lastSeen: t0)
        #expect(u.observe(sessionId: 10, logRange: r(0, 1), at: t0 + 10) == .newSession(.sessionIdChanged))
    }

    @Test func customGapThreshold() {
        var t = SessionTracker(gapThreshold: 30)
        _ = t.observe(sessionId: 0, logRange: r(10, 50), at: t0)
        #expect(t.observe(sessionId: 0, logRange: r(0, 60), at: t0 + 31) == .newSession(.returnedAfterGap))
    }
}
