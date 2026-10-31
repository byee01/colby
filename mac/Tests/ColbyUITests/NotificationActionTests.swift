#if canImport(UserNotifications) && canImport(AppKit)
import CombustionMacPlatform
import Testing
import UserNotifications

struct NotificationActionTests {
    @Test func bannerActionsMapToEngineCalls() {
        #expect(NotificationActionKind(actionIdentifier: UserNotificationPresenter.acknowledgeAction) == .acknowledge)
        #expect(NotificationActionKind(actionIdentifier: UserNotificationPresenter.snoozeAction) == .snooze)
        #expect(NotificationActionKind(actionIdentifier: UNNotificationDefaultActionIdentifier) == .open)
        #expect(NotificationActionKind(actionIdentifier: UNNotificationDismissActionIdentifier) == nil)
    }
}
#endif
