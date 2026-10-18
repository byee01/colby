import CombustionCodec
import CombustionCore
import Testing

struct BackfillPlannerTests {
    private func plan(_ existing: [UInt32], _ min: UInt32, _ max: UInt32, chunk: Int = 128) -> [ClosedRange<UInt32>] {
        BackfillPlanner.plan(existing: existing, range: LogRange(min: min, max: max), chunkSize: chunk)
    }

    private func seqs(_ r: ClosedRange<UInt32>) -> [UInt32] { Array(r) }

    @Test func emptyStoreSingleChunk() {
        #expect(plan([], 0, 99) == [0...99])
        #expect(plan([], 5, 5) == [5...5])
    }

    @Test func invertedRangeYieldsNothing() {
        #expect(plan([], 10, 5).isEmpty)
    }

    @Test func fullyStoredYieldsNothing() {
        #expect(plan(seqs(0...99), 0, 99).isEmpty)
        #expect(plan(seqs(0...200), 10, 50).isEmpty)
    }

    @Test func contiguousPrefixLeavesNewTail() {
        #expect(plan(seqs(0...49), 0, 99) == [50...99])
    }

    @Test func contiguousSuffixLeavesOldHead() {
        #expect(plan(seqs(50...99), 0, 99) == [0...49])
    }

    @Test func holesAreNewestFirst() {
        // present: 0-9, 20-29, 40-49; range 0...59 => holes 10-19, 30-39, 50-59
        let existing = seqs(0...9) + seqs(20...29) + seqs(40...49)
        #expect(plan(existing, 0, 59) == [50...59, 30...39, 10...19])
    }

    @Test func singleSeqHoles() {
        #expect(plan([0, 2, 4], 0, 5) == [5...5, 3...3, 1...1])
    }

    @Test func chunkingSplitsAtOneTwentyEightFromTheNewestEnd() {
        let p = plan([], 0, 299)
        #expect(p == [172...299, 44...171, 0...43])
        #expect(p.allSatisfy { $0.count <= 128 })
    }

    @Test func exactChunkMultiple() {
        #expect(plan([], 0, 255) == [128...255, 0...127])
        #expect(plan([], 0, 127) == [0...127])
        #expect(plan([], 0, 128) == [1...128, 0...0])
    }

    @Test func chunkingWithinHolesAndOrdering() {
        // hole A: 0-199 (200 long) ; present 200 ; hole B: 201-260 (60 long)
        let p = plan([200], 0, 260)
        #expect(p == [201...260, 72...199, 0...71])
    }

    @Test func existingOutsideRangeIgnored() {
        #expect(plan([0, 1, 2, 500, 600], 10, 20) == [10...20])
    }

    @Test func rangeMinAboveZeroAfterLogWrap() {
        #expect(plan(seqs(1000...1010), 1000, 1019) == [1011...1019])
    }

    @Test func duplicatesInExistingAreHarmless() {
        #expect(plan([3, 3, 3], 0, 5) == [4...5, 0...2])
    }

    @Test func customChunkSize() {
        #expect(plan([], 0, 9, chunk: 4) == [6...9, 2...5, 0...1])
        #expect(plan([], 0, 3, chunk: 0) == [3...3, 2...2, 1...1, 0...0])   // clamped to 1
    }

    @Test func extremeSeqValuesDoNotOverflow() {
        let max = UInt32.max
        #expect(plan([], max - 2, max) == [(max - 2)...max])
        #expect(plan([max], max - 1, max) == [(max - 1)...(max - 1)])
    }

    @Test func largeRandomPlansCoverExactlyTheMissingSeqs() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let hi = UInt32.random(in: 0...1500, using: &rng)
            let lo = UInt32.random(in: 0...hi, using: &rng)
            let existing = Set((0..<400).map { _ in UInt32.random(in: 0...1600, using: &rng) })
            let p = plan(Array(existing), lo, hi)
            let covered = p.flatMap { Array($0) }
            #expect(covered.count == Set(covered).count)                       // no overlap
            let missing = Set(lo...hi).subtracting(existing)
            #expect(Set(covered) == missing)                                   // exact cover
            #expect(p.allSatisfy { $0.count <= 128 })
            #expect(p.map(\.upperBound) == p.map(\.upperBound).sorted(by: >))  // newest first
        }
    }
}
