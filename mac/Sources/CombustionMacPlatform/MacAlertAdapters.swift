// macOS implementations of the alert platform protocols (docs/02 §9, 06 §7, §17.3).
// Compiles to an empty module off Apple platforms. Not yet compiled on macOS: verify in CI (docs/HANDOFF.md).
#if canImport(AppKit) && canImport(UserNotifications) && canImport(IOKit)
import AppKit
import CombustionCodec
import CombustionCore
import Foundation
import IOKit.pwr_mgt
import UserNotifications

// MARK: - Notifications

/// Posts alerts with `UNUserNotificationCenter` as time-sensitive notifications (needs the
/// `com.apple.developer.usernotifications.time-sensitive` entitlement), with Acknowledge and Snooze actions.
/// Ask for permission with `requestAuthorization()` when the first alert rule is enabled (06 §10), not at launch.
public final class UserNotificationPresenter: NotificationPresenting, @unchecked Sendable {
    public static let categoryId = "colby.alert"
    public static let acknowledgeAction = "colby.acknowledge"
    public static let snoozeAction = "colby.snooze"

    /// Title and body for an alert. The app passes one that knows probe nicknames and the units setting.
    public typealias Formatter = @Sendable (AlertInstance) -> (title: String, body: String)

    private let center: UNUserNotificationCenter
    private let format: Formatter

    public init(center: UNUserNotificationCenter = .current(), format: @escaping Formatter = UserNotificationPresenter.defaultText) {
        self.center = center
        self.format = format
        let ack = UNNotificationAction(identifier: Self.acknowledgeAction, title: "Acknowledge", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 5 min", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryId, actions: [ack, snooze], intentIdentifiers: [], options: [])
        ])
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Whether banners can be shown: authorized (or provisional) and alerts not turned off in System Settings.
    public func canShowBanners() async -> Bool {
        let s = await center.notificationSettings()
        let allowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        return allowed && s.alertSetting == .enabled
    }

    public func post(_ alert: AlertInstance) async {
        let text = format(alert)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        // System sound names are not addressable here; the looping sound plays in-app (SystemSoundPlayer).
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.categoryId
        content.threadIdentifier = alert.serial.hex
        content.userInfo = ["alertId": alert.id]
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        try? await center.add(request)
    }

    public func withdraw(id: String) async {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Plain wording without nicknames or units; the app should pass its own formatter.
    public static let defaultText: Formatter = { alert in
        let probe = "Probe \(alert.serial.hex)"
        switch alert.source {
        case .overheat(let sensor):
            return ("\(probe) is overheating", "Sensor \(sensor) is above its safe limit. Move the probe away from the heat.")
        case .probeAlarm(let kind, let channel):
            return ("\(probe) alarm", "\(channel) \(kind == .high ? "high" : "low") alarm.")
        case .rule(let rule):
            switch rule {
            case .predictionDone: return ("\(probe) is ready", "Remove from heat.")
            case .restingDone: return ("\(probe) has rested", "Resting is done.")
            case .predictionWithin(let s): return ("\(probe) is almost ready", "About \(s / 60) minutes left.")
            case .probeOffline: return ("\(probe) disconnected", "No data from the probe.")
            case .batteryLow: return ("\(probe) battery low", "Charge the probe before the next cook.")
            case .stall: return ("\(probe) may be stalling", "The core temperature has barely risen.")
            case .ambientOutOfRange: return ("\(probe) ambient out of range", "Check the heat source.")
            case .temperatureAbove, .temperatureBelow: return ("\(probe) temperature alert", "A temperature limit was crossed.")
            }
        }
    }
}

/// What the user did with a posted alert notification.
public enum NotificationActionKind: Sendable, Equatable {
    case acknowledge, snooze, open

    /// nil for a dismiss or an action that is not ours.
    public init?(actionIdentifier: String) {
        switch actionIdentifier {
        case UserNotificationPresenter.acknowledgeAction: self = .acknowledge
        case UserNotificationPresenter.snoozeAction: self = .snooze
        case UNNotificationDefaultActionIdentifier: self = .open
        default: return nil
        }
    }
}

/// `UNUserNotificationCenter` delegate: routes Acknowledge / Snooze / click on a banner to `handler` with the
/// alert id, and shows banners while the app is frontmost (without the notification sound: the alert's own
/// sound already plays in-app). Set it as the delegate before launch finishes; the center holds it weakly.
public final class NotificationActionRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public typealias Handler = @Sendable (NotificationActionKind, String) async -> Void
    private let handler: Handler

    public init(center: UNUserNotificationCenter = .current(), handler: @escaping Handler) {
        self.handler = handler
        super.init()
        center.delegate = self
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let kind = NotificationActionKind(actionIdentifier: response.actionIdentifier),
              let id = response.notification.request.content.userInfo["alertId"] as? String else { return }
        await handler(kind, id)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

// MARK: - Sound

/// Plays built-in system sounds with `NSSound` (06 §17.3), once or looped. Nothing is bundled; sounds are
/// played by name.
public final class SystemSoundPlayer: SoundPlaying, @unchecked Sendable {
    /// Built-in macOS sound per alert sound.
    public static let names: [AlertSound: String] = [
        .ready: "Glass", .overheat: "Sosumi", .probeAlarm: "Hero",
        .countdown: "Ping", .problem: "Basso", .custom: "Submarine",
    ]

    @MainActor private var playing: [String: NSSound] = [:]
    private let volume: Float

    /// - Parameter volume: 0...1 (Settings → Alarm volume, default 0.8).
    public init(volume: Float = 0.8) { self.volume = volume }

    public func play(_ sound: AlertSound) async {
        let name = Self.names[sound] ?? "Glass"
        let volume = self.volume
        await MainActor.run {
            guard let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
            s.volume = volume
            s.play()
        }
    }

    public func startLoop(_ sound: AlertSound, id: String) async {
        let name = Self.names[sound] ?? "Glass"
        let volume = self.volume
        await MainActor.run {
            playing[id]?.stop()
            guard let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
            s.loops = true
            s.volume = volume
            s.play()
            playing[id] = s
        }
    }

    public func stopLoop(id: String) async {
        await MainActor.run {
            playing[id]?.stop()
            playing[id] = nil
        }
    }
}

// MARK: - Keep awake

/// Prevents idle system sleep during a cook (`IOPMAssertion`) and opts out of App Nap
/// (`ProcessInfo.beginActivity`), so Bluetooth and alarms keep running (docs/02 §9).
public actor PowerAssertionKeepAwake: KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var activity: NSObjectProtocol?

    public init() {}

    public func setHeld(_ held: Bool) {
        if held, activity == nil {
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Colby: cook in progress" as CFString, &id)
            if rc == kIOReturnSuccess { assertion = id }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Colby: cook in progress")
        } else if !held, let a = activity {
            if assertion != 0 { IOPMAssertionRelease(assertion) }
            assertion = 0
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
}

// MARK: - Widget snapshot location

public enum LiveSnapshotLocation {
    /// The snapshot file in the App Group container shared with the WidgetKit extension; nil if the group is
    /// not in the entitlements.
    public static func appGroupURL(group: String, file: String = "live-snapshot.json") -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent(file)
    }
}
#endif
