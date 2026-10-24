// Builds the CombustionApp the UI runs on: live (CoreBluetooth + macOS alert adapters) or demo (simulated probes).
#if canImport(SwiftUI) && canImport(AppKit)
import CombustionCodec
import CombustionCore
import CombustionCoreBluetooth
import CombustionMacPlatform
import CombustionSim
import Foundation

public final class Runtime: @unchecked Sendable {
    public let app: CombustionApp
    public let clock: any Clock
    public let isDemo: Bool
    /// Asks for notification permission (06 §10: when the first alert rule is on; the default set is on).
    public let requestNotifications: @Sendable () async -> Void
    /// A notification banner was clicked (alert id). Set by `AppController`.
    @MainActor public var onOpenAlert: ((String) -> Void)?
    private var driver: Task<Void, Never>?
    private var demoProbes: [SimulatedProbe] = []
    private var router: NotificationActionRouter?

    private init(app: CombustionApp, clock: any Clock, isDemo: Bool, requestNotifications: @escaping @Sendable () async -> Void) {
        self.app = app
        self.clock = clock
        self.isDemo = isDemo
        self.requestNotifications = requestNotifications
    }

    deinit { driver?.cancel() }

    /// The real thing: CoreBluetooth, history in Application Support, notifications, looping sounds, keep-awake.
    public static func live(appGroup: String? = nil) throws -> Runtime {
        let clock = SystemClock()
        let notifications = UserNotificationPresenter { alert in
            let text = alertText(alert, format: Formatter(unit: .default()))
            return (text.title, text.detail ?? "")
        }
        let snapshot = appGroup
            .flatMap { LiveSnapshotLocation.appGroupURL(group: $0) }
            .map { FileLiveSnapshotWriter(url: $0) }
        let app = try CombustionApp(
            transport: CoreBluetoothTransport(clock: clock), clock: clock, databasePath: try databasePath(),
            alertSinks: [NotificationAlertSink(notifications), SoundAlertSink(SystemSoundPlayer())],
            keepAwake: PowerAssertionKeepAwake(), liveSnapshot: snapshot)
        let runtime = Runtime(app: app, clock: clock, isDemo: false) { _ = await notifications.requestAuthorization() }
        runtime.router = NotificationActionRouter { [weak runtime] kind, id in
            switch kind {
            case .acknowledge: await app.alerts.acknowledge(id)
            case .snooze: await app.alerts.snooze(id, duration: .seconds(300))
            case .open: await MainActor.run { runtime?.onOpenAlert?(id) }
            }
        }
        return runtime
    }

    /// Demo mode (06 §3, App Review): three simulated probes in the middle of a cook, in real time from now.
    /// Each probe gets a target; probe 1 finishes in about 10 minutes. Nothing touches Bluetooth or the disk.
    public static func demo(probes count: Int = 3) throws -> Runtime {
        let clock = TestClock(start: Date(), wakeGrace: .microseconds(200))
        let transport = SimulatedTransport(clock: clock)
        let app = try CombustionApp(
            transport: transport, clock: clock, alertSinks: [SoundAlertSink(SystemSoundPlayer())])
        let runtime = Runtime(app: app, clock: clock, isDemo: true) {}
        for i in 0..<max(1, min(count, 8)) {
            let probe = SimulatedProbe(
                serial: ProbeSerial(0x1000_0001 + UInt32(i)), transport: transport, clock: clock,
                sessionId: UInt32(100 + i), probeNumber: i + 1,
                curve: SimulatedProbe.cookCurve(offset: Double(i) * 3))
            // Records stamp backwards from now, so this is how far into the cook the demo starts.
            probe.preload(records: 900 - i * 120)
            // The simulator counts a new prediction down from a fixed time, not from the curve.
            probe.predictionLeadSeconds = [600, 2100, 4800][i % 3]
            probe.start()
            runtime.demoProbes.append(probe)
        }
        runtime.driver = Task {
            // Real time: one virtual second per real second.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await clock.advance(by: .seconds(1))
                await clock.settle()
            }
        }
        Task {
            // Targets once the links are up (the simulator predicts only with a target).
            try? await Task.sleep(for: .seconds(4))
            for (i, setpoint) in [63.0, 74, 85].prefix(runtime.demoProbes.count).enumerated() {
                try? await app.commands.setPrediction(
                    ProbeSerial(0x1000_0001 + UInt32(i)), mode: .timeToRemoval, setpoint: setpoint)
            }
        }
        return runtime
    }

    private static func databasePath() throws -> String {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Colby", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("colby.sqlite").path
    }
}
#endif
