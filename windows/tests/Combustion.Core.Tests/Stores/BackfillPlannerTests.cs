namespace Combustion.Core.Tests;

public class BackfillPlannerTests
{
    private static List<SeqRange> Plan(IEnumerable<uint> existing, uint min, uint max, int chunk = 128) =>
        BackfillPlanner.Plan(existing, new LogRange(min, max), chunk);

    private static SeqRange R(uint lower, uint upper) => new(lower, upper);

    private static IEnumerable<uint> Seqs(uint lower, uint upper) => R(lower, upper).Seqs();

    [Fact]
    public void EmptyStoreSingleChunk()
    {
        Assert.Equal([R(0, 99)], Plan([], 0, 99));
        Assert.Equal([R(5, 5)], Plan([], 5, 5));
    }

    [Fact]
    public void InvertedRangeYieldsNothing() => Assert.Empty(Plan([], 10, 5));

    [Fact]
    public void FullyStoredYieldsNothing()
    {
        Assert.Empty(Plan(Seqs(0, 99), 0, 99));
        Assert.Empty(Plan(Seqs(0, 200), 10, 50));
    }

    [Fact]
    public void ContiguousPrefixLeavesNewTail() => Assert.Equal([R(50, 99)], Plan(Seqs(0, 49), 0, 99));

    [Fact]
    public void ContiguousSuffixLeavesOldHead() => Assert.Equal([R(0, 49)], Plan(Seqs(50, 99), 0, 99));

    [Fact]
    public void HolesAreNewestFirst()
    {
        // present: 0-9, 20-29, 40-49; range 0...59 => holes 10-19, 30-39, 50-59
        var existing = Seqs(0, 9).Concat(Seqs(20, 29)).Concat(Seqs(40, 49));
        Assert.Equal([R(50, 59), R(30, 39), R(10, 19)], Plan(existing, 0, 59));
    }

    [Fact]
    public void SingleSeqHoles() => Assert.Equal([R(5, 5), R(3, 3), R(1, 1)], Plan([0, 2, 4], 0, 5));

    [Fact]
    public void ChunkingSplitsAtOneTwentyEightFromTheNewestEnd()
    {
        var p = Plan([], 0, 299);
        Assert.Equal([R(172, 299), R(44, 171), R(0, 43)], p);
        Assert.All(p, c => Assert.True(c.Count <= 128));
    }

    [Fact]
    public void ExactChunkMultiple()
    {
        Assert.Equal([R(128, 255), R(0, 127)], Plan([], 0, 255));
        Assert.Equal([R(0, 127)], Plan([], 0, 127));
        Assert.Equal([R(1, 128), R(0, 0)], Plan([], 0, 128));
    }

    [Fact]
    public void ChunkingWithinHolesAndOrdering()
    {
        // hole A: 0-199 (200 long) ; present 200 ; hole B: 201-260 (60 long)
        Assert.Equal([R(201, 260), R(72, 199), R(0, 71)], Plan([200], 0, 260));
    }

    [Fact]
    public void ExistingOutsideRangeIgnored() => Assert.Equal([R(10, 20)], Plan([0, 1, 2, 500, 600], 10, 20));

    [Fact]
    public void RangeMinAboveZeroAfterLogWrap() => Assert.Equal([R(1011, 1019)], Plan(Seqs(1000, 1010), 1000, 1019));

    [Fact]
    public void DuplicatesInExistingAreHarmless() => Assert.Equal([R(4, 5), R(0, 2)], Plan([3, 3, 3], 0, 5));

    [Fact]
    public void CustomChunkSize()
    {
        Assert.Equal([R(6, 9), R(2, 5), R(0, 1)], Plan([], 0, 9, chunk: 4));
        Assert.Equal([R(3, 3), R(2, 2), R(1, 1), R(0, 0)], Plan([], 0, 3, chunk: 0)); // clamped to 1
    }

    [Fact]
    public void ExtremeSeqValuesDoNotOverflow()
    {
        const uint max = uint.MaxValue;
        Assert.Equal([R(max - 2, max)], Plan([], max - 2, max));
        Assert.Equal([R(max - 1, max - 1)], Plan([max], max - 1, max));
    }

    [Fact]
    public void LargeRandomPlansCoverExactlyTheMissingSeqs()
    {
        var rng = new Random();
        for (var n = 0; n < 50; n++)
        {
            var hi = (uint)rng.Next(0, 1501);
            var lo = (uint)rng.Next(0, (int)hi + 1);
            var existing = Enumerable.Range(0, 400).Select(_ => (uint)rng.Next(0, 1601)).ToHashSet();
            var p = Plan(existing, lo, hi);
            var covered = p.SelectMany(c => c.Seqs()).ToList();
            Assert.Equal(covered.Count, covered.ToHashSet().Count); // no overlap
            var missing = Seqs(lo, hi).ToHashSet();
            missing.ExceptWith(existing);
            Assert.True(missing.SetEquals(covered)); // exact cover
            Assert.All(p, c => Assert.True(c.Count <= 128));
            var uppers = p.Select(c => c.Upper).ToList();
            Assert.Equal(uppers.OrderDescending(), uppers); // newest first
        }
    }
}
