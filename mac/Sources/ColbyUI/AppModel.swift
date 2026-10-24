#if canImport(SwiftUI) && canImport(AppKit)
import CombustionCodec
import CombustionCore
import Foundation
import Observation

/// The UI's view of `CombustionApp`, on the main actor. Mirrors the facade's streams into plain properties.
///
/// Every probe that advertises is followed (06 §10: "defaults: follow all found"; onboarding will let the user
/// choose). `probes` lists followed probes by probe number.
@MainActor @Observable
public final class AppModel {
    public private(set) var bluetooth: BluetoothState = .poweredOn
    public private(set) var probes: [ProbeSnapshot] = []
    public private(set) var predictions: [ProbeSerial: PredictionView] = [:]
    /// Most urgent first (06 §7). Includes acknowledged and snoozed alerts until their condition clears.
    public private(set) var alerts: [AlertInstance] = []
    /// The alerts that should demand attention now (band, bell, popover); most urgent first.
    public var firing: [AlertInstance] { alerts.filter { $0.state == .firing } }
    /// Snoozed alerts: shown muted, with Acknowledge, so a snooze is never invisible.
    public var snoozed: [AlertInstance] { alerts.filter { $0.state == .snoozed } }
    /// History of the selected probe's current session.
    public private(set) var series: TemperatureSeries?
    /// The selected probe's Instant Read readings (°C) over the last 30 s, for the sparkline.
    public private(set) var instantReadTrail = InstantReadTrail()
    public private(set) var now: Date
    /// The probe on the graph. Until the user picks one it follows the lowest probe number.
    public var selected: ProbeSerial? {
        didSet {
            if !autoSelecting { userSelected = true }
            if selected != oldValue {
                instantReadTrail = InstantReadTrail()
                watchSeries()
            }
        }
    }
    public var unit: TemperatureUnit = .default()
    /// false when macOS will not show Colby's banners (permission denied or alerts off); nil when unknown.
    public private(set) var notificationsAllowed: Bool?
    public var format: Formatter { Formatter(unit: unit) }
    /// The probe whose Set target sheet is open (the inspector button and Probe ▸ Set Target… open it).
    public var targetSheet: ProbeSerial?
    public let isDemo: Bool

    private let runtime: Runtime
    /// The facade, for tools (colby-shots) and sheets that send commands.
    public var app: CombustionApp { runtime.app }
    private var tasks: [Task<Void, Never>] = []
    private var predictionTasks: [ProbeSerial: Task<Void, Never>] = [:]
    private var seriesTask: Task<Void, Never>?
    private var seriesKey: SessionKey?
    private var followed: Set<ProbeSerial> = []
    private var all: [ProbeSerial: ProbeSnapshot] = [:]
    private var userSelected = false
    private var autoSelecting = false

    public init(runtime: Runtime) {
        self.runtime = runtime
        self.isDemo = runtime.isDemo
        self.now = runtime.clock.now()
    }

    public var selectedProbe: ProbeSnapshot? {
        probes.first { $0.serial == selected } ?? probes.first
    }

    public func prediction(_ serial: ProbeSerial) -> PredictionView? { predictions[serial] }

    // MARK: Lifecycle

    public func start() async {
        let app = self.app
        let bluetooth = app.bluetoothState
        let snapshots = app.probes.probes
        let followed = app.probes.followed
        let alerts = app.alerts.active
        tasks.append(Task { for await s in bluetooth { self.bluetooth = s } })
        tasks.append(Task { for await f in followed { self.followed = f; self.refreshProbes() } })
        tasks.append(Task { for await a in alerts { self.alerts = a } })
        tasks.append(Task {
            for await map in snapshots {
                self.all = map
                for serial in map.keys where !self.followed.contains(serial) {
                    self.followed.insert(serial)
                    await app.follow(serial)
                }
                self.refreshProbes()
            }
        })
        tasks.append(Task {
            // Drives relative text ("Offline 3m") and the series' session check.
            while !Task.isCancelled {
                self.now = self.runtime.clock.now()
                self.checkSession()
                try? await Task.sleep(for: .seconds(1))
            }
        })
        await app.start()
        await runtime.requestNotifications()
        let allowed = runtime.notificationsAllowed
        tasks.append(Task {
            // Rechecked, since the user can change it in System Settings at any time.
            while !Task.isCancelled {
                self.notificationsAllowed = await allowed()
                try? await Task.sleep(for: .seconds(10))
            }
        })
    }

    public func stop() async {
        for t in tasks { t.cancel() }
        for t in predictionTasks.values { t.cancel() }
        seriesTask?.cancel()
        await app.stop()
    }

    // MARK: Actions

    public func acknowledge(_ alert: AlertInstance) {
        Task { await app.alerts.acknowledge(alert.id) }
    }

    public func snooze(_ alert: AlertInstance, minutes: Int = 5) {
        Task { await app.alerts.snooze(alert.id, duration: .seconds(minutes * 60)) }
    }

    /// Starts or changes the prediction; returns once a status shows it (02 §8), throws `CommandError` otherwise.
    public func setTarget(_ serial: ProbeSerial, mode: PredictionMode, celsius: Double) async throws {
        try await app.commands.setPrediction(serial, mode: mode, setpoint: celsius)
    }

    public func clearTarget(_ serial: ProbeSerial) async throws {
        try await app.commands.cancelPrediction(serial)
    }

    // MARK: Streams

    private func refreshProbes() {
        probes = all.values.filter { followed.contains($0.serial) }
            .sorted { ($0.probeNumber, $0.serial) < ($1.probeNumber, $1.serial) }
        for p in probes where predictionTasks[p.serial] == nil {
            let stream = app.predictions(p.serial)
            predictionTasks[p.serial] = Task { for await v in stream { self.predictions[p.serial] = v } }
        }
        if !userSelected || !probes.contains(where: { $0.serial == selected }) {
            autoSelecting = true
            selected = probes.first?.serial
            autoSelecting = false
        }
        if let p = selectedProbe { instantReadTrail.add(p.mode == .instantRead ? p.instantRead : nil, at: p.receivedAt) }
    }

    private func watchSeries() {
        seriesTask?.cancel()
        seriesTask = nil
        seriesKey = nil
        series = nil
        checkSession()
    }

    /// Follows the selected probe's current session; a new session (charger cycle) switches the graph to it.
    private func checkSession() {
        guard let serial = selectedProbe?.serial else { return }
        let history = app.history
        Task {
            guard let key = try? await history.currentSession(of: serial), key != self.seriesKey,
                  serial == self.selectedProbe?.serial else { return }
            self.seriesKey = key
            self.seriesTask?.cancel()
            let stream = await history.series(key)
            self.seriesTask = Task { for await s in stream { self.series = s } }
        }
    }
}
#endif
