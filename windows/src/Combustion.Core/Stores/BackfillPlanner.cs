using Combustion.Codec;

namespace Combustion.Core;

/// <summary>An inclusive range of log sequence numbers (Swift <c>ClosedRange&lt;UInt32&gt;</c>).</summary>
public readonly record struct SeqRange(uint Lower, uint Upper)
{
    public bool Contains(uint seq) => seq >= Lower && seq <= Upper;

    /// <summary>Number of seqs; a long because <c>0...UInt32.max</c> holds 2^32.</summary>
    public long Count => (long)Upper - Lower + 1;

    public IEnumerable<uint> Seqs()
    {
        for (var s = (long)Lower; s <= Upper; s++)
        {
            yield return (uint)s;
        }
    }

    public override string ToString() => $"{Lower}...{Upper}";
}

/// <summary>Plans Read Logs requests to fill the holes in a session. docs/02 §6.3. Pure.</summary>
public static class BackfillPlanner
{
    public const int DefaultChunkSize = 128;

    /// <summary>
    /// Missing seqs within <paramref name="range"/> (inclusive), as inclusive request ranges of at most
    /// <paramref name="chunkSize"/> records. Newest first (so the graph fills from the right); every chunk is aligned to
    /// the top of its hole. Seqs in <paramref name="existing"/> outside <paramref name="range"/> are ignored. Holes are
    /// never merged across stored records.
    /// </summary>
    public static List<SeqRange> Plan(IEnumerable<uint> existing, LogRange range, int chunkSize = DefaultChunkSize)
    {
        long lo = range.Min, hi = range.Max;
        if (lo > hi)
        {
            return [];
        }
        long size = Math.Max(1, chunkSize);

        var present = existing.Distinct().Select(s => (long)s).Where(s => s >= lo && s <= hi).Order();
        var holes = new List<(long Lo, long Hi)>();
        var cursor = lo;
        foreach (var s in present)
        {
            if (s > cursor)
            {
                holes.Add((cursor, s - 1));
            }
            cursor = s + 1;
        }
        if (cursor <= hi)
        {
            holes.Add((cursor, hi));
        }

        var output = new List<SeqRange>();
        for (var h = holes.Count - 1; h >= 0; h--)
        {
            var (holeLo, holeHi) = holes[h];
            var top = holeHi;
            while (true)
            {
                var start = Math.Max(holeLo, top - (size - 1));
                output.Add(new SeqRange((uint)start, (uint)top));
                if (start == holeLo)
                {
                    break;
                }
                top = start - 1;
            }
        }
        return output;
    }
}
