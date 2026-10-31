import CombustionCodec
import Foundation

/// Failures of a probe command. docs/02 §8.
public enum CommandError: Error, Sendable, Equatable {
    /// No link can carry the command right now.
    case notReachable
    /// A value outside what the probe accepts (set point 0...102.3 °C, alarm -20...799 °C).
    case outOfRange(field: String)
    /// `setAlarm` needs the probe's current alarms (read-modify-write) and no full status has arrived yet.
    case alarmStateUnknown
    /// The probe acknowledged the command but no status showed the new value in time.
    case notConfirmed
    case uart(UartError)
}

/// One way to deliver a command to a probe: a direct link, later a MeatNet node link.
public protocol CommandRoute: Sendable {
    /// Sends `request` for `probe` and returns the response. Throws `UartError` (or `CancellationError`).
    func send(_ request: UartRequest, to probe: ProbeSerial, timeout: Duration) async throws -> UartResponse
}

/// Picks the route for a probe: direct link if connected, else a node link, else nil. docs/02 §8.
public protocol CommandRouting: Sendable {
    func commandRoute(for probe: ProbeSerial) -> (any CommandRoute)?
}

extension DirectProbeLink: CommandRoute {
    public func send(_ request: UartRequest, to probe: ProbeSerial, timeout: Duration) async throws -> UartResponse {
        guard probe == serial else { throw UartError.failure }
        return try await uart.send(request, timeout: timeout, retries: 1)
    }
}

extension NodeLink: CommandRoute {
    public func send(_ request: UartRequest, to probe: ProbeSerial, timeout: Duration) async throws -> UartResponse {
        try await send(request, probe: probe, timeout: timeout, retries: 1)
    }
}

/// What the alert engine needs from `Commands`.
public protocol ProbeAlarmSilencing: Sendable {
    func silenceAlarms(_ serial: ProbeSerial) async throws
}

public enum AlarmKind: Sendable, Hashable {
    case high, low
}

/// Set prediction, set alarms and silence alarms. docs/02 §8.
///
/// Every command is confirmed by the next status, not by the UART ack alone: after the ack the actor waits up to
/// `confirmTimeout` for a status in which the probe shows the new value, and throws `notConfirmed` if none comes.
/// The wait runs on the injected `Clock`. Commands for one probe run one at a time (so two `setAlarm` calls
/// cannot overwrite each other's read-modify-write); different probes run in parallel.
public actor Commands: ProbeAlarmSilencing {
    public static let commandTimeout: Duration = .seconds(3)
    public static let confirmTimeout: Duration = .seconds(5)

    private let probes: ProbeStore
    private let routing: any CommandRouting
    private let clock: any Clock
    private let trace: (any TraceSink)?
    private let commandTimeout: Duration
    private let confirmTimeout: Duration

    private var busy: Set<ProbeSerial> = []
    private var waiters: [ProbeSerial: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        probes: ProbeStore, routing: any CommandRouting, clock: any Clock, trace: (any TraceSink)? = nil,
        commandTimeout: Duration = Commands.commandTimeout, confirmTimeout: Duration = Commands.confirmTimeout
    ) {
        self.probes = probes
        self.routing = routing
        self.clock = clock
        self.trace = trace
        self.commandTimeout = commandTimeout
        self.confirmTimeout = confirmTimeout
    }

    // MARK: Prediction

    /// Starts a prediction. `mode` must be `timeToRemoval` or `removalAndResting`; use `cancelPrediction` for none.
    public func setPrediction(_ serial: ProbeSerial, mode: PredictionMode, setpoint: Double) async throws {
        guard mode == .timeToRemoval || mode == .removalAndResting else { throw CommandError.outOfRange(field: "mode") }
        try Self.validateSetpoint(setpoint)
        try await run("setPrediction", serial, .setPrediction(setpoint: setpoint, mode: mode)) { status in
            let p = status.prediction
            return p.mode == mode && abs(p.setpoint - setpoint) < Self.tolerance
        }
    }

    /// Ends the prediction (mode none).
    public func cancelPrediction(_ serial: ProbeSerial) async throws {
        try await run("cancelPrediction", serial, .setPrediction(setpoint: 0, mode: .none)) { $0.prediction.mode == .none }
    }

    // MARK: Alarms

    /// Sets or clears one alarm (`temperature == nil` clears it), leaving the other 21 as the probe has them.
    public func setAlarm(_ serial: ProbeSerial, channel: AlarmChannel, kind: AlarmKind, temperature: Double?) async throws {
        if let temperature { try Self.validateAlarm(temperature, field: "temperature") }
        try await exclusive(serial) {
            guard let current = await probes.snapshot(of: serial)?.alarms else { throw CommandError.alarmStateUnknown }
            var config = Self.clean(current)
            let alarm = temperature.map { Alarm(isSet: true, temperature: $0) } ?? Alarm.unset
            switch kind {
            case .high: config.high[channel] = alarm
            case .low: config.low[channel] = alarm
            }
            let wanted = config
            try await send("setAlarm", serial, .setAlarms(wanted)) { Self.matches($0.alarms, wanted) }
        }
    }

    /// Replaces all 22 alarms. A channel missing from the config is sent as unset.
    public func setAlarms(_ serial: ProbeSerial, _ config: AlarmConfig) async throws {
        for (kind, alarms) in [("high", config.high), ("low", config.low)] {
            for (channel, alarm) in alarms where alarm.isSet {
                try Self.validateAlarm(alarm.temperature, field: "\(kind).\(channel)")
            }
        }
        let clean = Self.clean(config)
        try await run("setAlarms", serial, .setAlarms(clean)) { Self.matches($0.alarms, clean) }
    }

    /// Silences every alarming alarm on the probe (and so on its Display and phone). Overheat is not silenced.
    public func silenceAlarms(_ serial: ProbeSerial) async throws {
        try await run("silenceAlarms", serial, .silenceAlarms) { status in
            guard let alarms = status.alarms else { return false }
            return !(Array(alarms.high.values) + Array(alarms.low.values)).contains { $0.alarming }
        }
    }

    // MARK: Validation and matching

    /// Probe resolution is 0.1 °C and the codec rounds to it, but the probe can report one step off what it was
    /// sent: on hardware (fw 2.3.3) a set point sent as 294 (85 °F) came back as 293. One step either way confirms.
    private static let tolerance = 0.11

    private static func validateSetpoint(_ value: Double) throws {
        guard value.isFinite, (0...maxPredictionSetpoint).contains(value) else {
            throw CommandError.outOfRange(field: "setpoint")
        }
    }

    private static func validateAlarm(_ value: Double, field: String) throws {
        guard value.isFinite, Alarm.temperatureRange.contains(value) else {
            throw CommandError.outOfRange(field: field)
        }
    }

    /// Read-only bits are ignored by the probe on write; send them cleared.
    private static func clean(_ config: AlarmConfig) -> AlarmConfig {
        func strip(_ alarms: [AlarmChannel: Alarm]) -> [AlarmChannel: Alarm] {
            alarms.mapValues { Alarm(isSet: $0.isSet, temperature: $0.temperature) }
        }
        return AlarmConfig(high: strip(config.high), low: strip(config.low))
    }

    /// Every alarm of `wanted` is as the probe reports it (set flag, and temperature when set).
    private static func matches(_ reported: AlarmConfig?, _ wanted: AlarmConfig) -> Bool {
        guard let reported else { return false }
        func same(_ got: [AlarmChannel: Alarm], _ want: [AlarmChannel: Alarm]) -> Bool {
            AlarmChannel.allCases.allSatisfy { ch in
                let w = want[ch] ?? .unset
                guard let g = got[ch] else { return !w.isSet }
                return g.isSet == w.isSet && (!w.isSet || abs(g.temperature - w.temperature) < tolerance)
            }
        }
        return same(reported.high, wanted.high) && same(reported.low, wanted.low)
    }

    // MARK: Sending

    private func run(
        _ op: String, _ serial: ProbeSerial, _ request: UartRequest,
        confirmedBy confirmed: @escaping @Sendable (ProbeStatusPayload) -> Bool
    ) async throws {
        try await exclusive(serial) { try await send(op, serial, request, confirmedBy: confirmed) }
    }

    /// Sends and confirms. Runs inside `exclusive`.
    private func send(
        _ op: String, _ serial: ProbeSerial, _ request: UartRequest,
        confirmedBy confirmed: @escaping @Sendable (ProbeStatusPayload) -> Bool
    ) async throws {
        do {
            guard let route = routing.commandRoute(for: serial) else { throw CommandError.notReachable }
            // Subscribe before sending: the confirming status can arrive before the ack does.
            let statuses = probes.statusEvents
            do {
                _ = try await route.send(request, to: serial, timeout: commandTimeout)
            } catch let e as UartError {
                throw CommandError.uart(e)
            }
            guard await waitForStatus(statuses, serial, confirmed) else { throw CommandError.notConfirmed }
            trace?.emit("command", ["op": .string(op), "serial": .serial(serial.rawValue), "result": .string("confirmed")])
        } catch let e as CommandError {
            trace?.emit("command", ["op": .string(op), "serial": .serial(serial.rawValue), "result": .string(Self.describe(e))])
            throw e
        }
    }

    /// True once a status for `serial` satisfies `confirmed`; false after `confirmTimeout` on the clock.
    private func waitForStatus(
        _ statuses: AsyncStream<ProbeStatusEvent>, _ serial: ProbeSerial,
        _ confirmed: @escaping @Sendable (ProbeStatusPayload) -> Bool
    ) async -> Bool {
        let clock = self.clock
        let timeout = confirmTimeout
        enum Outcome { case matched, timedOut, streamEnded }
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                for await e in statuses where e.serial == serial && confirmed(e.status) { return .matched }
                return .streamEnded
            }
            group.addTask {
                do { try await clock.sleep(for: timeout) } catch { return .timedOut }
                return .timedOut
            }
            // A stream that ended early must not cut the wait short; only a match or the timer decides.
            var matched = false
            for await outcome in group where outcome != .streamEnded {
                matched = outcome == .matched
                break
            }
            group.cancelAll()
            return matched
        }
    }

    private static func describe(_ e: CommandError) -> String {
        switch e {
        case .notReachable: return "notReachable"
        case .outOfRange(let f): return "outOfRange:\(f)"
        case .alarmStateUnknown: return "alarmStateUnknown"
        case .notConfirmed: return "notConfirmed"
        case .uart(let u): return "uart:\(u)"
        }
    }

    // MARK: One command at a time per probe

    private func exclusive<T: Sendable>(_ serial: ProbeSerial, _ body: () async throws -> T) async throws -> T {
        if busy.contains(serial) {
            await withCheckedContinuation { waiters[serial, default: []].append($0) }
        } else {
            busy.insert(serial)
        }
        defer {
            if var queue = waiters[serial], !queue.isEmpty {
                queue.removeFirst().resume()
                waiters[serial] = queue
            } else {
                waiters[serial] = nil
                busy.remove(serial)
            }
        }
        return try await body()
    }
}
