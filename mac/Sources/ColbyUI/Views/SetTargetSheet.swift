// Set target sheet (06 §5, components.md SetTarget).
#if canImport(SwiftUI) && canImport(AppKit)
import CombustionCodec
import CombustionCore
import SwiftUI

/// Target in the user's unit, mode as two radio cards, Clear / Cancel / Set. Set waits for the probe to confirm.
public struct SetTargetSheet: View {
    var model: AppModel
    var serial: ProbeSerial
    var dismiss: () -> Void

    @State private var text: String
    @State private var mode: PredictionMode
    @State private var pending: Pending?
    @State private var failure: String?
    @FocusState private var fieldFocused: Bool

    enum Pending { case set, clear }

    public init(model: AppModel, serial: ProbeSerial, dismiss: @escaping () -> Void) {
        self.model = model
        self.serial = serial
        self.dismiss = dismiss
        let current = model.prediction(serial).flatMap { $0.mode == .none ? nil : $0 }
        _text = State(initialValue: current.map { TargetEntry.text($0.setpoint, unit: model.unit) } ?? "")
        _mode = State(initialValue: current?.mode ?? .timeToRemoval)
    }

    public var body: some View {
        let unit = model.unit
        let parsed = TargetEntry.parse(text, unit: unit)
        let problem: TargetEntry.Problem? = if case .failure(let p) = parsed { p } else { nil }
        let probe = model.probes.first { $0.serial == serial }
        let hasTarget = model.prediction(serial).map { $0.mode != .none } ?? false

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if let probe { ProbeBadge(number: probe.probeNumber, color: probe.color, size: 24) }
                Text("Set target").font(F.title).foregroundStyle(P.text)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Cooking to").font(F.caption).foregroundStyle(P.text2)
                HStack(spacing: 10) {
                    TextField("", text: $text, prompt: Text(unit == .fahrenheit ? "203" : "95"))
                        .textFieldStyle(.plain)
                        .font(F.numeric(28))
                        .foregroundStyle(P.text)
                        .padding(.horizontal, 12)
                        .frame(width: 120, height: 48)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(P.window))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(problem == .notANumber || problem == .outOfRange ? P.critical : P.line))
                        .focused($fieldFocused)
                        .onSubmit(set)
                        .accessibilityLabel("Target core temperature")
                    Text(unit.symbol).font(F.numeric(24)).foregroundStyle(P.text2)
                    Spacer()
                    if let core = probe?.virtual.core {
                        Text("Core now " + format(core, unit)).font(F.numeric(15)).foregroundStyle(P.muted)
                    }
                }
                Text(TargetEntry.help(problem, unit: unit)).font(F.caption)
                    .foregroundStyle(problem == .notANumber || problem == .outOfRange ? P.criticalText : P.muted)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prediction").font(F.caption).foregroundStyle(P.text2)
                modeCard(.timeToRemoval, "Ready in", "Time until it reaches the target")
                modeCard(.removalAndResting, "Ready in + rest", "Pull early; reaches the target while resting")
            }

            if let failure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(P.warning)
                    Text(failure).font(F.caption).foregroundStyle(P.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(P.warningBg))
            }

            HStack(spacing: 10) {
                if hasTarget {
                    Button(action: clear) {
                        HStack(spacing: 6) {
                            if pending == .clear { ProgressView().controlSize(.small) }
                            Text("Clear target")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(pending != nil)
                }
                Spacer()
                Button("Cancel", action: dismiss).buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action: set) {
                    HStack(spacing: 6) {
                        if pending == .set { ProgressView().controlSize(.small) }
                        Text(pending == .set ? "Setting…" : failure != nil ? "Retry" : "Set")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || pending != nil)
                .opacity(problem != nil ? 0.5 : 1)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(P.card)
        .preferredColorScheme(.dark)
        .onAppear { fieldFocused = true }
    }

    private func modeCard(_ m: PredictionMode, _ title: String, _ detail: String) -> some View {
        let on = mode == m
        return Button { mode = m } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? P.core : P.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(F.label).foregroundStyle(P.text)
                    Text(detail).font(F.caption).foregroundStyle(P.muted)
                }
                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(on ? P.raised : P.window))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(on ? P.core : P.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func format(_ celsius: Double, _ unit: TemperatureUnit) -> String {
        String(format: "%.1f", unit.convert(celsius)) + unit.symbol
    }

    private func set() {
        guard pending == nil, case .success(let celsius) = TargetEntry.parse(text, unit: model.unit) else { return }
        run(.set) { try await model.setTarget(serial, mode: mode, celsius: celsius) }
    }

    private func clear() {
        guard pending == nil else { return }
        run(.clear) { try await model.clearTarget(serial) }
    }

    private func run(_ kind: Pending, _ command: @escaping @MainActor () async throws -> Void) {
        pending = kind
        failure = nil
        Task {
            do {
                try await command()
                pending = nil
                dismiss()
            } catch {
                pending = nil
                failure = commandFailureText(error)
            }
        }
    }
}
#endif
