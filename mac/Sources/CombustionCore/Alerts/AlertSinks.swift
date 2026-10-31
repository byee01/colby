import CombustionCodec
import Foundation

/// Where alert events go: notifications, sound, the UI. docs/02 §9. Events arrive in order, one at a time.
public protocol AlertSink: Sendable {
    func deliver(_ event: AlertEvent) async
}

/// Keeps the computer from sleeping while a cook is active (docs/02 §9). The engine calls it only when the
/// answer changes. macOS: `IOPMAssertion` + `ProcessInfo.beginActivity`; Windows: `PowerSetRequest`.
public protocol KeepAwake: Sendable {
    func setHeld(_ held: Bool) async
}

// MARK: - Platform abstractions behind the stock sinks

/// Posts and withdraws OS notifications. macOS: `UNUserNotificationCenter` (`.timeSensitive`); Windows: alarm toast.
public protocol NotificationPresenting: Sendable {
    func post(_ alert: AlertInstance) async
    func withdraw(id: String) async
}

/// Plays alert sounds, once or in a loop until stopped. macOS: `NSSound`; Windows: `MediaPlayer`.
public protocol SoundPlaying: Sendable {
    func play(_ sound: AlertSound) async
    func startLoop(_ sound: AlertSound, id: String) async
    func stopLoop(id: String) async
}

/// Notification sink: posts when an alert starts firing (again), withdraws it when it is snoozed or clears.
/// Acknowledging withdraws too, except for overheat: the banner stays until the probe is cool again (06 §7).
public struct NotificationAlertSink: AlertSink {
    private let presenter: any NotificationPresenting

    public init(_ presenter: any NotificationPresenting) { self.presenter = presenter }

    public func deliver(_ event: AlertEvent) async {
        switch event.to {
        case .firing:
            await presenter.post(event.instance)
        case .acknowledged:
            if case .overheat = event.instance.source { return }
            await presenter.withdraw(id: event.instance.id)
        case .snoozed, .idle:
            await presenter.withdraw(id: event.instance.id)
        }
    }
}

/// Sound sink (06 §17.3): a looping sound plays from the moment the alert fires until it is acknowledged,
/// snoozed or clears; any other sound plays once each time the alert fires.
public struct SoundAlertSink: AlertSink {
    private let player: any SoundPlaying

    public init(_ player: any SoundPlaying) { self.player = player }

    public func deliver(_ event: AlertEvent) async {
        let sound = event.instance.sound
        if event.to == .firing {
            if sound.loops {
                await player.startLoop(sound, id: event.instance.id)
            } else {
                await player.play(sound)
            }
        } else if event.from == .firing, sound.loops {
            await player.stopLoop(id: event.instance.id)
        }
    }
}

// MARK: - Test doubles

/// Collects every event.
public final class RecordingAlertSink: AlertSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AlertEvent] = []

    public init() {}

    public var events: [AlertEvent] { lock.withLock { stored } }
    /// `"<id> idle->firing"` per event, for compact assertions.
    public var transitions: [String] { events.map { "\($0.instance.id) \($0.transition)" } }

    public func deliver(_ event: AlertEvent) async { lock.withLock { stored.append(event) } }
}

/// A sound player that remembers which loops are running and what played once.
public final class FakeSoundPlayer: SoundPlaying, @unchecked Sendable {
    public struct Loop: Sendable, Equatable {
        public var sound: AlertSound
        public var id: String
    }

    private let lock = NSLock()
    private var running: [String: AlertSound] = [:]
    private var log: [String] = []

    public init() {}

    /// Loops playing right now, by alert id.
    public var playing: [String: AlertSound] { lock.withLock { running } }
    /// `"start <id>"` / `"stop <id>"` / `"once <sound>"`, in order.
    public var history: [String] { lock.withLock { log } }

    public func play(_ sound: AlertSound) async {
        lock.withLock { log.append("once \(sound)") }
    }

    public func startLoop(_ sound: AlertSound, id: String) async {
        lock.withLock {
            running[id] = sound
            log.append("start \(id)")
        }
    }

    public func stopLoop(id: String) async {
        lock.withLock {
            running[id] = nil
            log.append("stop \(id)")
        }
    }
}

/// A notification presenter that remembers what is on screen.
public final class FakeNotificationPresenter: NotificationPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [String: AlertInstance] = [:]
    private var log: [String] = []

    public init() {}

    public var visible: [String: AlertInstance] { lock.withLock { shown } }
    public var history: [String] { lock.withLock { log } }

    public func post(_ alert: AlertInstance) async {
        lock.withLock {
            shown[alert.id] = alert
            log.append("post \(alert.id)")
        }
    }

    public func withdraw(id: String) async {
        lock.withLock {
            shown[id] = nil
            log.append("withdraw \(id)")
        }
    }
}

/// Records the assertion: `held` now, and every change in order.
public final class FakeKeepAwake: KeepAwake, @unchecked Sendable {
    private let lock = NSLock()
    private var current = false
    private var changes: [Bool] = []

    public init() {}

    public var isHeld: Bool { lock.withLock { current } }
    public var history: [Bool] { lock.withLock { changes } }

    public func setHeld(_ held: Bool) async {
        lock.withLock {
            current = held
            changes.append(held)
        }
    }
}

/// A silencer that records calls and can be made to fail.
public final class FakeSilencer: ProbeAlarmSilencing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ProbeSerial] = []
    private var failure: (any Error)?

    public init() {}

    public var silenced: [ProbeSerial] { lock.withLock { calls } }
    /// Makes the next call throw `error`.
    public func failNext(with error: (any Error)?) { lock.withLock { failure = error } }

    public func silenceAlarms(_ serial: ProbeSerial) async throws {
        let error: (any Error)? = lock.withLock {
            calls.append(serial)
            defer { failure = nil }
            return failure
        }
        if let error { throw error }
    }
}
