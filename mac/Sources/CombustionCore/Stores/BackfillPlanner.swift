import CombustionCodec
import Foundation

/// Plans Read Logs requests to fill the holes in a session. docs/02 §6.3. Pure.
public enum BackfillPlanner {
    public static let defaultChunkSize = 128

    /// Missing seqs within `range` (inclusive), as inclusive request ranges of at most `chunkSize` records.
    /// Newest first (so the graph fills from the right); every chunk is aligned to the top of its hole.
    /// Seqs in `existing` outside `range` are ignored. Holes are never merged across stored records.
    public static func plan(existing: some Sequence<UInt32>, range: LogRange,
                            chunkSize: Int = defaultChunkSize) -> [ClosedRange<UInt32>] {
        let lo = Int64(range.min), hi = Int64(range.max)
        guard lo <= hi else { return [] }
        let size = Int64(max(1, chunkSize))

        let present = Set(existing).lazy.map(Int64.init).filter { $0 >= lo && $0 <= hi }.sorted()
        var holes: [(Int64, Int64)] = []
        var cursor = lo
        for s in present {
            if s > cursor { holes.append((cursor, s - 1)) }
            cursor = s + 1
        }
        if cursor <= hi { holes.append((cursor, hi)) }

        var out: [ClosedRange<UInt32>] = []
        for (holeLo, holeHi) in holes.reversed() {
            var top = holeHi
            while true {
                let start = max(holeLo, top - (size - 1))
                out.append(UInt32(start)...UInt32(top))
                if start == holeLo { break }
                top = start - 1
            }
        }
        return out
    }
}
