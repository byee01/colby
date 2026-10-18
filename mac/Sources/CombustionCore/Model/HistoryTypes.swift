import CombustionCodec
import Foundation

/// Identifies one cook. docs/02 §2 defines `(serial, sessionId)`; because `sessionId = 0` repeats across
/// cooks on old firmware (docs/02 §11), `startedAt` (ms precision, as stored) completes the key.
public struct SessionKey: Hashable, Sendable {
    public var serial: ProbeSerial
    public var sessionId: UInt32
    public var startedAtMs: Int64

    public init(serial: ProbeSerial, sessionId: UInt32, startedAtMs: Int64) {
        self.serial = serial
        self.sessionId = sessionId
        self.startedAtMs = startedAtMs
    }

    public init(serial: ProbeSerial, sessionId: UInt32, startedAt: Date) {
        self.init(serial: serial, sessionId: sessionId, startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1000).rounded()))
    }

    public var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
}

/// docs/02 §6.3: predictive if a setpoint was set at any point.
public enum SessionKind: String, Sendable, Hashable {
    case predictive, manual
}

/// `time(seq) = anchorTime − (anchorSeq − seq) × samplePeriod` (docs/02 §6.3).
public enum TimeDerivation {
    public static func time(seq: UInt32, anchorSeq: UInt32, anchorTime: Date, samplePeriod: TimeInterval) -> Date {
        anchorTime.addingTimeInterval(-(Double(anchorSeq) - Double(seq)) * samplePeriod)
    }

    /// Inverse, fractional: where `time` falls on the seq axis.
    public static func seq(at time: Date, anchorSeq: UInt32, anchorTime: Date, samplePeriod: TimeInterval) -> Double {
        Double(anchorSeq) - anchorTime.timeIntervalSince(time) / samplePeriod
    }
}

/// One log record with its derived time. docs/02 §3.
public struct TemperatureSample: Sendable, Equatable {
    public var seq: UInt32
    public var time: Date
    /// T1...T8 in °C.
    public var temperatures: [Double]
    public var virtualSensors: VirtualSensors
    public var prediction: PredictionLog

    public init(seq: UInt32, time: Date, temperatures: [Double], virtualSensors: VirtualSensors, prediction: PredictionLog) {
        self.seq = seq
        self.time = time
        self.temperatures = temperatures
        self.virtualSensors = virtualSensors
        self.prediction = prediction
    }

    public var core: Double { temperatures[Int(virtualSensors.core.rawValue)] }
    public var surface: Double { temperatures[Int(virtualSensors.surface.rawValue)] }
    public var ambient: Double { temperatures[Int(virtualSensors.ambient.rawValue)] }
}

public struct MinMax: Sendable, Equatable {
    public var min: Double
    public var max: Double
    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }
}

/// One bucket of a downsampled series: min and max of each virtual channel so spikes stay visible.
public struct TemperatureBucket: Sendable, Equatable {
    public var firstSeq: UInt32
    public var lastSeq: UInt32
    public var startTime: Date
    public var endTime: Date
    public var sampleCount: Int
    public var core: MinMax
    public var surface: MinMax
    public var ambient: MinMax
}

/// All stored samples of one session, times derived from the latest anchor. docs/02 §3, §6.3.
public struct TemperatureSeries: Sendable, Equatable {
    public var key: SessionKey
    public var samplePeriod: TimeInterval
    public var anchorSeq: UInt32
    public var anchorTime: Date
    /// Ascending by seq. May have holes (gaps not yet backfilled).
    public var samples: [TemperatureSample]

    public init(key: SessionKey, samplePeriod: TimeInterval, anchorSeq: UInt32, anchorTime: Date, samples: [TemperatureSample]) {
        self.key = key
        self.samplePeriod = samplePeriod
        self.anchorSeq = anchorSeq
        self.anchorTime = anchorTime
        self.samples = samples
    }

    /// At most `maxPoints` buckets of equal seq width (empty buckets are skipped), each with the
    /// min and max of core, surface and ambient. With `samples.count <= maxPoints` every bucket
    /// holds one sample (min == max).
    public func downsampled(maxPoints: Int) -> [TemperatureBucket] {
        guard maxPoints > 0, let first = samples.first, let last = samples.last else { return [] }
        let span = Int(last.seq) - Int(first.seq) + 1
        let buckets = Swift.min(maxPoints, span)
        var out: [TemperatureBucket] = []
        out.reserveCapacity(buckets)
        var currentIndex = -1
        for s in samples {
            let idx = (Int(s.seq) - Int(first.seq)) * buckets / span
            let (c, f, a) = (s.core, s.surface, s.ambient)
            if idx == currentIndex {
                var b = out[out.count - 1]
                b.lastSeq = s.seq
                b.endTime = s.time
                b.sampleCount += 1
                b.core = MinMax(min: Swift.min(b.core.min, c), max: Swift.max(b.core.max, c))
                b.surface = MinMax(min: Swift.min(b.surface.min, f), max: Swift.max(b.surface.max, f))
                b.ambient = MinMax(min: Swift.min(b.ambient.min, a), max: Swift.max(b.ambient.max, a))
                out[out.count - 1] = b
            } else {
                currentIndex = idx
                out.append(TemperatureBucket(
                    firstSeq: s.seq, lastSeq: s.seq, startTime: s.time, endTime: s.time, sampleCount: 1,
                    core: MinMax(min: c, max: c), surface: MinMax(min: f, max: f), ambient: MinMax(min: a, max: a)))
            }
        }
        return out
    }
}

public struct ThumbnailPoint: Sendable, Equatable {
    public var core: Double
    public var surface: Double
    public var ambient: Double
    public init(core: Double, surface: Double, ambient: Double) {
        self.core = core
        self.surface = surface
        self.ambient = ambient
    }
}

public enum Thumbnail {
    public static let pointCount = 60

    /// 60 evenly spaced (by seq) points, linearly interpolated between neighbours. Empty if no samples.
    public static func make(from samples: [TemperatureSample]) -> [ThumbnailPoint] {
        guard let first = samples.first, let last = samples.last else { return [] }
        let lo = Double(first.seq), hi = Double(last.seq)
        var out: [ThumbnailPoint] = []
        out.reserveCapacity(pointCount)
        var j = 0
        for i in 0..<pointCount {
            let target = lo + (hi - lo) * Double(i) / Double(pointCount - 1)
            while j + 1 < samples.count, Double(samples[j + 1].seq) <= target { j += 1 }
            let a = samples[j]
            if j + 1 < samples.count, Double(a.seq) < target {
                let b = samples[j + 1]
                let f = (target - Double(a.seq)) / Double(b.seq - a.seq)
                out.append(ThumbnailPoint(
                    core: a.core + (b.core - a.core) * f,
                    surface: a.surface + (b.surface - a.surface) * f,
                    ambient: a.ambient + (b.ambient - a.ambient) * f))
            } else {
                out.append(ThumbnailPoint(core: a.core, surface: a.surface, ambient: a.ambient))
            }
        }
        return out
    }

    /// Float32 little-endian, core/surface/ambient per point.
    public static func encode(_ points: [ThumbnailPoint]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(points.count * 12)
        for p in points {
            for v in [p.core, p.surface, p.ambient] {
                let bits = Float(v).bitPattern
                for s in stride(from: 0, to: 32, by: 8) { out.append(UInt8((bits >> UInt32(s)) & 0xFF)) }
            }
        }
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> [ThumbnailPoint] {
        guard bytes.count % 12 == 0 else { return [] }
        func float(at o: Int) -> Double {
            var bits: UInt32 = 0
            for k in 0..<4 { bits |= UInt32(bytes[o + k]) << UInt32(8 * k) }
            return Double(Float(bitPattern: bits))
        }
        return stride(from: 0, to: bytes.count, by: 12).map {
            ThumbnailPoint(core: float(at: $0), surface: float(at: $0 + 4), ambient: float(at: $0 + 8))
        }
    }
}

/// One row of the history list. docs/02 §6.3, §18.
public struct SessionSummary: Sendable, Equatable {
    public var key: SessionKey
    public var start: Date
    /// nil while the session is still open (live).
    public var end: Date?
    public var peakCore: Double?
    /// Setpoint of the last predictive sample, if any.
    public var setpoint: Double?
    public var kind: SessionKind
    public var nickname: String?
    public var sampleCount: Int
    public var samplePeriod: TimeInterval
    public var readySince: Date?
    /// 60 points; computed at session end, on the fly for open sessions. Empty without samples.
    public var thumbnail: [ThumbnailPoint]
}

/// Scrub readout. docs/02 §6.3 `valueAt`.
public struct SessionValue: Sendable, Equatable {
    public var time: Date
    /// Nearest stored seq.
    public var seq: UInt32
    public var core: Double
    public var surface: Double
    public var ambient: Double
    /// Prediction log of the nearest sample.
    public var prediction: PredictionLog
    public var predictionState: PredictionState { prediction.state }
}
