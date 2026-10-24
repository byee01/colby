// Main window (06 §4): header with ReadyBlock, readout row, graph, probe chips; inspector on the right.
#if canImport(SwiftUI) && canImport(AppKit)
import CombustionCodec
import CombustionCore
import SwiftUI

public struct MainView: View {
    @Bindable var model: AppModel
    var tryDemo: (() -> Void)?
    @State private var range: GraphRange = .live
    @State private var scrub: ScrubPoint?

    public init(model: AppModel, tryDemo: (() -> Void)? = nil) {
        self.model = model
        self.tryDemo = tryDemo
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let alert = model.alerts.first {
                let text = alertText(alert, format: model.format)
                AlertBand(title: text.title, detail: text.detail, count: model.alerts.count,
                          acknowledge: { model.acknowledge(alert) }, snooze: { model.snooze(alert) })
            }
            content
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(P.window)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $range) {
                    ForEach(GraphRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Units", selection: $model.unit) {
                    Text("°F").tag(TemperatureUnit.fahrenheit)
                    Text("°C").tag(TemperatureUnit.celsius)
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle(model.isDemo ? "Colby — Demo" : "Colby")
    }

    @ViewBuilder private var content: some View {
        switch model.bluetooth {
        case .poweredOff:
            StatusPanel(icon: "antenna.radiowaves.left.and.right.slash", title: "Bluetooth is off",
                        message: "Turn on Bluetooth to see your probes.",
                        action: ("Open Bluetooth Settings", { open("x-apple.systempreferences:com.apple.BluetoothSettings") }),
                        secondary: tryDemo.map { ("Try demo mode", $0) })
        case .unauthorized:
            StatusPanel(icon: "lock", title: "Colby can't use Bluetooth",
                        message: "Allow Colby in Privacy & Security → Bluetooth.",
                        action: ("Open Privacy Settings",
                                 { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") }),
                        secondary: tryDemo.map { ("Try demo mode", $0) })
        case .unsupported:
            StatusPanel(icon: "exclamationmark.triangle", title: "No Bluetooth LE",
                        message: "This Mac has no Bluetooth Low Energy radio.", action: nil,
                        secondary: tryDemo.map { ("Try demo mode", $0) })
        case .poweredOn:
            if let probe = model.selectedProbe {
                HStack(spacing: 0) {
                    probeColumn(probe)
                    Inspector(snapshot: probe, prediction: model.prediction(probe.serial), format: model.format)
                        .frame(width: 320)
                }
            } else {
                StatusPanel(icon: "dot.radiowaves.left.and.right", title: "Looking for probes",
                            message: "Take a probe out of its charger to wake it.", action: nil,
                            secondary: tryDemo.map { ("Try demo mode", $0) })
            }
        }
    }

    private func probeColumn(_ probe: ProbeSnapshot) -> some View {
        let prediction = model.prediction(probe.serial)
        let format = model.format
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HStack(spacing: 12) {
                    ProbeBadge(number: probe.probeNumber, color: probe.color, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(probe.serial.displayName).font(F.header).foregroundStyle(P.text)
                        Text(subtitle(probe, prediction)).font(F.caption).foregroundStyle(P.muted)
                    }
                }
                Spacer()
                if let ready = ReadyText(prediction, format: format) { ReadyBlock(text: ready) }
            }
            if probe.mode == .instantRead {
                InstantReadView(celsius: probe.instantRead, format: format)
            } else {
                ReadoutRow(
                    core: format.temperature(scrub?.core ?? probe.virtual.core),
                    surface: format.temperature(scrub?.surface ?? probe.virtual.surface),
                    ambient: format.temperature(scrub?.ambient ?? probe.virtual.ambient),
                    dimmed: probe.isOffline)
                Text(scrub.map { "History · " + format.clock($0.time) } ?? "Now · " + format.clock(model.now))
                    .font(F.label).foregroundStyle(P.text2)
                    .frame(maxWidth: .infinity)
                TempGraph(series: model.series, target: prediction.flatMap { $0.mode == .none ? nil : $0.setpoint },
                          range: range, now: model.now, format: format, scrub: $scrub)
                    .frame(minHeight: 260)
            }
            if model.probes.count > 4 {
                ScrollView(.horizontal, showsIndicators: false) { chips(probe, format) }
            } else if model.probes.count > 1 {
                chips(probe, format)
            }
        }
        .padding(20)
    }

    private func chips(_ probe: ProbeSnapshot, _ format: Formatter) -> some View {
        HStack(spacing: 10) {
            ForEach(model.probes, id: \.serial) { p in
                ProbeChip(snapshot: p, prediction: model.prediction(p.serial), selected: p.serial == probe.serial,
                          alerting: model.alerts.contains { $0.serial == p.serial }, now: model.now, format: format)
                    .onTapGesture { model.selected = p.serial }
            }
        }
    }

    private func subtitle(_ probe: ProbeSnapshot, _ p: PredictionView?) -> String {
        var parts: [String] = []
        switch p?.mode {
        case .timeToRemoval?, .removalAndResting?: parts.append("Predictive Cook")
        default: parts.append(probe.prediction?.state == .notInserted ? "Not inserted" : "Manual Cook")
        }
        if probe.isOffline {
            parts.append("offline " + model.format.elapsed(model.now.timeIntervalSince(probe.receivedAt)))
        } else if p?.isStale == true {
            parts.append("stale")
        }
        return parts.joined(separator: " · ")
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

/// Instant Read (components.md): a single large number while the probe is in Instant Read mode.
struct InstantReadView: View {
    var celsius: Double?
    var format: Formatter

    var body: some View {
        let parts = format.instantRead(celsius)
        VStack(spacing: 12) {
            Text("Instant Read").font(F.label).foregroundStyle(P.text2)
                .padding(.horizontal, 14).padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(P.text2))
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(parts.whole).font(F.numeric(220)).foregroundStyle(P.text)
                Text(parts.fraction).font(F.numeric(88)).foregroundStyle(P.text2)
            }
            .minimumScaleFactor(0.3)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Right-hand panel: target and progress, all eight sensors, battery, link.
struct Inspector: View {
    var snapshot: ProbeSnapshot
    var prediction: PredictionView?
    var format: Formatter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
                if let p = prediction, p.mode != .none {
                    section("Cooking to " + format.temperatureWithUnit(p.setpoint)) {
                        if let pct = p.percentToRemoval {
                            HStack(spacing: 10) {
                                ProgressBar(fraction: pct / 100)
                                Text("\(Int(pct))%").font(F.numeric(18)).foregroundStyle(P.text2)
                            }
                        }
                    }
                } else {
                    section("No target") {
                        Text("Set a target on the probe's Display or phone app; editing here comes next.")
                            .font(F.caption).foregroundStyle(P.muted)
                    }
                }
                section("Sensors") {
                    ForEach(0..<8, id: \.self) { i in
                        HStack {
                            Text("T\(i + 1)").font(F.label).foregroundStyle(P.text2)
                            if let role = role(i) { Text(role).font(F.caption).foregroundStyle(P.muted) }
                            Spacer()
                            Text(format.temperature(snapshot.temperatures[safe: i] ?? nil))
                                .font(F.numeric(20)).foregroundStyle(P.text)
                        }
                    }
                }
                section("Probe") {
                    row("Serial", snapshot.serial.hex)
                    row("Battery", snapshot.batteryLow ? "Low" : "OK")
                    row("Connection", connection)
                    if let rssi = snapshot.link.primary?.rssi { row("Signal", "\(rssi) dBm") }
                }
                Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(P.card)
    }

    private var connection: String {
        guard let s = snapshot.link.primary else { return "Offline" }
        switch s.kind {
        case .directConnection: return "Connected"
        case .nodeConnection: return "Via \(s.via ?? "node")" + (s.hopCount.map { " · \($0) hop\($0 == 1 ? "" : "s")" } ?? "")
        case .nodeAdvertisement: return "Repeated by \(s.via ?? "node")"
        case .advertisement: return "Advertisements only"
        }
    }

    private func role(_ i: Int) -> String? {
        let v = snapshot.virtual
        if Int(v.coreSensor.rawValue) == i { return "Core" }
        if Int(v.surfaceSensor.rawValue) == i { return "Surface" }
        if Int(v.ambientSensor.rawValue) == i { return "Ambient" }
        return nil
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(F.label).foregroundStyle(P.text)
            content()
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(F.caption).foregroundStyle(P.muted)
            Spacer()
            Text(v).font(F.caption).foregroundStyle(P.text2)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
