// Menu bar extra (06 §9, components.md MenuBarItem / PopoverList).
#if canImport(SwiftUI) && canImport(AppKit)
import CombustionCodec
import CombustionCore
import SwiftUI

/// Resting text: the soonest-finishing probe's core, countdown and completion time; with no prediction, the
/// first probe's core; nothing followed, icon only. Alarm: bell.
public struct MenuBarLabel: View {
    var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let format = model.format
        if !model.firing.isEmpty {
            Label(menuText(format) ?? "Alert", systemImage: "bell.fill")
        } else if let text = menuText(format) {
            Label(text, systemImage: "thermometer.medium")
        } else {
            Image(systemName: "thermometer.medium")
        }
    }

    private func menuText(_ format: Formatter) -> String? {
        let predicting = model.probes.compactMap { p -> (ProbeSnapshot, PredictionView, UInt32)? in
            guard let v = model.prediction(p.serial), v.state == .predicting, let s = v.secondsRemaining else { return nil }
            return (p, v, s)
        }
        if let (p, v, s) = predicting.min(by: { $0.2 < $1.2 }) {
            var text = "\(p.probeNumber) · \(format.temperature(p.virtual.core)) · \(format.countdown(s))"
            if let at = v.readyAt { text += " " + format.clock(at) }
            return text
        }
        if let ready = model.probes.first(where: { model.prediction($0.serial)?.state == .removalPredictionDone }) {
            return "\(ready.probeNumber) · Ready"
        }
        guard let p = model.probes.first(where: { !$0.isOffline }) ?? model.probes.first else { return nil }
        return "\(p.probeNumber) · \(format.temperature(p.virtual.core))"
    }
}

/// Popover: active alerts first, one row per probe, then Open / Quit.
public struct MenuBarContent: View {
    var model: AppModel
    var openWindow: () -> Void

    public init(model: AppModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
    }

    public var body: some View {
        let format = model.format
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.firing, id: \.id) { alert in
                let text = alertText(alert, format: format)
                HStack {
                    Image(systemName: "bell.fill").foregroundStyle(P.critical)
                    Text(text.title).font(F.label).foregroundStyle(P.criticalText)
                    Spacer()
                    Button("Acknowledge") { model.acknowledge(alert) }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(P.criticalBg))
            }
            ForEach(model.snoozed, id: \.id) { alert in
                HStack {
                    Image(systemName: "bell.slash").foregroundStyle(P.muted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alertText(alert, format: format).title).font(F.label).foregroundStyle(P.text2)
                        if let until = alert.snoozedUntil {
                            Text("Snoozed until " + format.clock(until)).font(F.caption).foregroundStyle(P.muted)
                        }
                    }
                    Spacer()
                    Button("Acknowledge") { model.acknowledge(alert) }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(P.raised))
            }
            if model.probes.isEmpty {
                Text("No probes yet. Take one out of its charger.").font(F.body).foregroundStyle(P.text2)
            }
            ForEach(model.probes, id: \.serial) { p in
                row(p, format)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selected = p.serial
                        openWindow()
                    }
            }
            Divider().overlay(P.line)
            HStack {
                Button("Open Colby", action: openWindow).buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(P.window)
        .preferredColorScheme(.dark)
    }

    private func row(_ p: ProbeSnapshot, _ format: Formatter) -> some View {
        let prediction = model.prediction(p.serial)
        return HStack(spacing: 10) {
            ProbeBadge(number: p.probeNumber, color: p.color, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.serial.displayName).font(F.label).foregroundStyle(P.text)
                HStack(spacing: 4) {
                    Text(format.temperature(p.virtual.core)).foregroundStyle(P.core)
                    if let v = prediction, v.mode != .none {
                        Text("→ " + format.temperature(v.setpoint)).foregroundStyle(P.muted)
                    }
                }
                .font(F.numeric(18))
            }
            Spacer()
            if let ready = ReadyText(prediction, format: format) {
                ReadyBlock(text: ready, compact: true)
            } else if let status = chipStatus(p, prediction, now: model.now, format: format) {
                Text(status).font(F.label).foregroundStyle(P.muted)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(P.card))
        .opacity(p.isOffline ? 0.5 : 1)
    }
}
#endif
