// TempGraph (components.md, 06 §4.1): core / surface / ambient over time, target line, hover scrub.
#if canImport(SwiftUI) && canImport(AppKit)
import CombustionCore
import SwiftUI

/// The visible time window. `live` follows now with 30 minutes.
public enum GraphRange: String, CaseIterable, Identifiable, Sendable {
    case live = "Live", hour = "1h", fourHours = "4h", all = "All"
    public var id: String { rawValue }

    var span: TimeInterval? {
        switch self {
        case .live: 30 * 60
        case .hour: 3600
        case .fourHours: 4 * 3600
        case .all: nil
        }
    }
}

/// The sample under the pointer while scrubbing.
struct ScrubPoint: Equatable {
    var time: Date
    var core: Double?
    var surface: Double?
    var ambient: Double?
}

/// Plot geometry and data, separate from drawing so the math can be tested.
struct GraphModel {
    /// Temperatures in °C; `y(_:in:)` converts to the display unit.
    struct Point { var time: Date; var core: Double; var surface: Double; var ambient: Double }

    var points: [Point]
    var unit: TemperatureUnit
    /// Indices where a new segment starts (missing data is a break).
    var breaks: Set<Int>
    var start: Date
    var end: Date
    /// Axis range and step in the display unit.
    var yMin: Double
    var yMax: Double
    var yStep: Double
    /// °C.
    var target: Double?

    init(series: TemperatureSeries?, target celsius: Double?, range: GraphRange, now: Date, width: CGFloat,
         unit: TemperatureUnit) {
        let buckets = series?.downsampled(maxPoints: max(2, Int(width * 2))) ?? []
        var pts: [Point] = []
        var breaks: Set<Int> = []
        var lastSeq: UInt32?
        for b in buckets {
            if let lastSeq, b.firstSeq > lastSeq + 1 + UInt32(b.lastSeq - b.firstSeq) { breaks.insert(pts.count) }
            lastSeq = b.lastSeq
            let mid = b.startTime.addingTimeInterval(b.endTime.timeIntervalSince(b.startTime) / 2)
            pts.append(Point(
                time: mid, core: (b.core.min + b.core.max) / 2, surface: (b.surface.min + b.surface.max) / 2,
                ambient: (b.ambient.min + b.ambient.max) / 2))
        }
        let first = pts.first?.time ?? now.addingTimeInterval(-1800)
        let end = max(now, pts.last?.time ?? now)
        var start = range.span.map { max(first, end.addingTimeInterval(-$0)) } ?? first
        if end.timeIntervalSince(start) < 60 { start = end.addingTimeInterval(-60) }

        // 06 §4.1: 50° to max(ambient, target) + 30, rounded to 50; ticks 50, or 100 above a 300° span.
        let visible = pts.filter { $0.time >= start }
        let hi = unit.convert(max(visible.map { max($0.ambient, $0.core, $0.surface) }.max() ?? 0, celsius ?? 0)) + 30
        let lo = min(visible.map { unit.convert(min($0.ambient, $0.core, $0.surface)) }.min() ?? 50, 50)
        let yMin = (lo / 50).rounded(.down) * 50
        let yMax = max(yMin + 50, (hi / 50).rounded(.up) * 50)
        self.start = start
        self.end = end
        self.yMin = yMin
        self.yMax = yMax
        yStep = yMax - yMin > 300 ? 100 : 50
        points = pts
        self.unit = unit
        self.breaks = breaks
        target = celsius
    }

    func x(_ t: Date, in rect: CGRect) -> CGFloat {
        rect.minX + rect.width * CGFloat(t.timeIntervalSince(start) / end.timeIntervalSince(start))
    }

    /// `celsius` mapped to the plot; axis values are already in the display unit.
    func y(_ celsius: Double, in rect: CGRect) -> CGFloat { y(display: unit.convert(celsius), in: rect) }

    func y(display v: Double, in rect: CGRect) -> CGFloat {
        rect.maxY - rect.height * CGFloat((v - yMin) / (yMax - yMin))
    }

    func time(atX x: CGFloat, in rect: CGRect) -> Date {
        start.addingTimeInterval(end.timeIntervalSince(start) * Double((x - rect.minX) / rect.width))
    }

    /// The nearest point to `time`, if it is within two buckets of it.
    func nearest(_ time: Date) -> Point? {
        guard !points.isEmpty else { return nil }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { $0 >= 0 && $0 < points.count }
        return candidates.map { points[$0] }.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }

    /// Hour or half-hour ticks, about one per 120 px.
    func timeTicks(width: CGFloat) -> [Date] {
        let span = end.timeIntervalSince(start)
        let wanted = max(1, Double(width) / 120)
        let steps: [TimeInterval] = [300, 600, 900, 1800, 3600, 7200, 14400]
        let step = steps.first { span / $0 <= wanted } ?? 14400
        var t = (start.timeIntervalSince1970 / step).rounded(.up) * step
        var out: [Date] = []
        while t <= end.timeIntervalSince1970 {
            out.append(Date(timeIntervalSince1970: t))
            t += step
        }
        return out
    }
}

struct TempGraph: View {
    var series: TemperatureSeries?
    var target: Double?
    var range: GraphRange
    var now: Date
    var format: Formatter
    @Binding var scrub: ScrubPoint?

    private let leftAxis: CGFloat = 48
    private let rightAxis: CGFloat = 52
    private let bottomAxis: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: leftAxis, y: 16, width: max(1, geo.size.width - leftAxis - rightAxis),
                              height: max(1, geo.size.height - 16 - bottomAxis))
            let model = GraphModel(series: series, target: target, range: range, now: now, width: plot.width,
                                   unit: format.unit)
            Canvas { ctx, _ in draw(model, in: plot, ctx) }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p) where plot.contains(p):
                        if let pt = model.nearest(model.time(atX: p.x, in: plot)) {
                            scrub = ScrubPoint(time: pt.time, core: pt.core, surface: pt.surface, ambient: pt.ambient)
                        }
                    default:
                        scrub = nil
                    }
                }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(P.card))
        .accessibilityElement()
        .accessibilityLabel("Temperature graph")
    }

    private func draw(_ m: GraphModel, in plot: CGRect, _ ctx: GraphicsContext) {
        // Grid and y labels.
        var v = m.yMin
        while v <= m.yMax {
            let y = m.y(display: v, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(line, with: .color(P.grid), lineWidth: 1.5)
            ctx.draw(Text("\(Int(v))°").font(F.axis).foregroundStyle(P.muted),
                     at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
            v += m.yStep
        }
        for t in m.timeTicks(width: plot.width) {
            ctx.draw(Text(format.clock(t)).font(F.axis).foregroundStyle(P.muted),
                     at: CGPoint(x: m.x(t, in: plot), y: plot.maxY + 6), anchor: .top)
        }
        // Target.
        if let target = m.target, m.unit.convert(target) <= m.yMax {
            let y = m.y(target, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(line, with: .color(P.targetLine), lineWidth: 1.5)
            ctx.draw(Text(format.temperature(target)).font(F.axis).foregroundStyle(P.targetLine),
                     at: CGPoint(x: plot.maxX + 8, y: y), anchor: .leading)
        }
        // Series, clipped to the plot, ambient first so core is on top.
        var clipped = ctx
        clipped.clip(to: Path(plot))
        for (value, color) in [(\GraphModel.Point.ambient, P.ambient), (\.surface, P.surface), (\.core, P.core)] {
            var path = Path()
            for (i, p) in m.points.enumerated() {
                let pt = CGPoint(x: m.x(p.time, in: plot), y: m.y(p[keyPath: value], in: plot))
                if i == 0 || m.breaks.contains(i) { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            clipped.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        // Scrub line and dots.
        if let s = scrub {
            let x = m.x(s.time, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            ctx.stroke(line, with: .color(P.targetLine), lineWidth: 2.5)
            for (value, color) in [(s.ambient, P.ambient), (s.surface, P.surface), (s.core, P.core)] {
                guard let value else { continue }
                let c = CGPoint(x: x, y: m.y(value, in: plot))
                let dot = Path(ellipseIn: CGRect(x: c.x - 8.5, y: c.y - 8.5, width: 17, height: 17))
                ctx.fill(dot, with: .color(color))
                ctx.stroke(dot, with: .color(.white), lineWidth: 3)
            }
        }
    }
}
#endif
