// Shared components (docs/design/components.md).
#if canImport(SwiftUI) && canImport(AppKit)
import CombustionCodec
import CombustionCore
import SwiftUI

typealias P = Theme.Palette
typealias F = Theme.Fonts

/// Probe number in a neutral circle with a ring in the probe's physical colour.
public struct ProbeBadge: View {
    var number: Int
    var color: ProbeColor
    var size: CGFloat = 26

    public var body: some View {
        Text("\(number)")
            .font(F.numeric(size * 0.58))
            .foregroundStyle(P.text)
            .frame(width: size, height: size)
            .background(Circle().fill(P.badgeFill))
            .overlay(Circle().strokeBorder(color == .grey ? P.ringGrey : P.ringYellow, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// Coloured pill naming a virtual sensor.
struct SensorPill: View {
    var title: String
    var color: Color

    var body: some View {
        Text(title)
            .font(F.label)
            .foregroundStyle(P.pillText)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
    }
}

/// Caption, primary time, secondary time.
struct ReadyBlock: View {
    var text: ReadyText
    var compact = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(text.caption).font(compact ? F.caption : F.label).foregroundStyle(P.muted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text.primary)
                    .font(compact ? F.numeric(30, .semibold) : F.countdown)
                    .foregroundStyle(color)
                if let s = text.secondary {
                    Text(s).font(compact ? F.numeric(16) : F.secondaryTime).foregroundStyle(P.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch text.tone {
        case .normal: P.text
        case .ready: P.ready
        case .muted: P.disabled
        }
    }
}

/// Core / Surface / Ambient pills over large numbers. Shows `values` (scrub) when set, else live.
struct ReadoutRow: View {
    var core: String
    var surface: String
    var ambient: String
    var dimmed = false

    var body: some View {
        HStack(spacing: 0) {
            column("Core", P.core, core)
            Rectangle().fill(P.line).frame(width: 3)
            column("Surface", P.surface, surface)
            Rectangle().fill(P.line).frame(width: 3)
            column("Ambient", P.ambient, ambient)
        }
        .frame(height: 118)
        .opacity(dimmed ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Core \(core), surface \(surface), ambient \(ambient)")
    }

    private func column(_ title: String, _ color: Color, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SensorPill(title: title, color: color)
            Text(value).font(F.readout).foregroundStyle(P.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

/// One probe in the strip under the graph (shown when more than one probe is followed).
struct ProbeChip: View {
    var snapshot: ProbeSnapshot
    var prediction: PredictionView?
    var selected: Bool
    var alerting: Bool
    var now: Date
    var format: Formatter

    var body: some View {
        let status = chipStatus(snapshot, prediction, now: now, format: format)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProbeBadge(number: snapshot.probeNumber, color: snapshot.color)
                Text(snapshot.serial.displayName).font(F.label).foregroundStyle(P.text).lineLimit(1)
                Spacer(minLength: 0)
                if snapshot.batteryLow {
                    Image(systemName: "battery.25").foregroundStyle(P.warning).accessibilityLabel("Battery low")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(format.temperature(snapshot.virtual.core)).font(F.chipValue).foregroundStyle(P.core)
                if let target = prediction.flatMap({ $0.mode == .none ? nil : $0.setpoint }) {
                    Text("→ " + format.temperature(target)).font(F.numeric(18)).foregroundStyle(P.muted)
                }
                Spacer(minLength: 0)
                if let status {
                    Text(status).font(F.numeric(20, .semibold)).foregroundStyle(statusColor(status))
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(selected ? P.raised : P.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip)
            .strokeBorder(alerting ? P.critical : selected ? P.text2 : .clear, lineWidth: 1.5))
        .opacity(snapshot.isOffline ? 0.5 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Probe \(snapshot.probeNumber), \(status ?? "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "Ready": P.ready
        case "Overheat": P.critical
        default: snapshot.isOffline || s == "Stale" ? P.muted : P.text
        }
    }
}

/// Progress toward the removal temperature.
struct ProgressBar: View {
    var fraction: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(P.raised)
                Capsule().fill(P.core).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Red band under the toolbar for the most urgent alert.
struct AlertBand: View {
    var title: String
    var detail: String?
    var count: Int
    var acknowledge: () -> Void
    var snooze: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill").foregroundStyle(P.critical)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(F.label).foregroundStyle(P.criticalText)
                if let detail { Text(detail).font(F.caption).foregroundStyle(P.criticalText.opacity(0.8)) }
            }
            if count > 1 { Text("+\(count - 1) more").font(F.caption).foregroundStyle(P.criticalText) }
            Spacer()
            Button("Snooze 5 min", action: snooze).buttonStyle(SecondaryButtonStyle())
            Button("Acknowledge", action: acknowledge).buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(P.criticalBg)
        .overlay(alignment: .bottom) { Rectangle().fill(P.critical).frame(height: 2) }
    }
}

/// Centered empty state: icon, title, one line, one action.
struct StatusPanel: View {
    var icon: String
    var title: String
    var message: String
    var action: (title: String, run: () -> Void)?
    var secondary: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(P.muted)
            Text(title).font(F.title).foregroundStyle(P.text)
            Text(message).font(F.body).foregroundStyle(P.text2).multilineTextAlignment(.center)
            if let action { Button(action.title, action: action.run).buttonStyle(PrimaryButtonStyle()) }
            if let secondary { Button(secondary.title, action: secondary.run).buttonStyle(.link) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(F.label)
            .foregroundStyle(P.primaryText)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(P.primaryBg))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(F.label)
            .foregroundStyle(P.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(P.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(P.line))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Title and detail for an alert, shared by the band, popover and notifications.
func alertText(_ a: AlertInstance, format: Formatter) -> (title: String, detail: String?) {
    let probe = a.serial.displayName
    switch a.source {
    case .overheat(let s): return ("\(probe) is overheating", "Sensor \(s). Move it away from the heat.")
    case .probeAlarm(let kind, let channel):
        return ("\(probe) \(kind == .high ? "high" : "low") alarm", "\(channel)".capitalized)
    case .rule(let kind):
        switch kind {
        case .predictionDone: return ("\(probe): Remove now", "Target reached.")
        case .restingDone: return ("\(probe): Rested", "Ready to serve.")
        case .predictionWithin(let s): return ("\(probe): ready in \(s / 60) min", nil)
        case .probeOffline: return ("\(probe) disconnected", "No data from the probe.")
        case .batteryLow: return ("\(probe) battery low", "Charge it before the next cook.")
        case .stall: return ("\(probe) may be stalling", nil)
        case .ambientOutOfRange: return ("\(probe) ambient out of range", nil)
        case .temperatureAbove(_, let c, _): return ("\(probe) above \(format.temperatureWithUnit(c))", nil)
        case .temperatureBelow(_, let c, _): return ("\(probe) below \(format.temperatureWithUnit(c))", nil)
        }
    }
}
#endif
