import Foundation
import UserNotifications
import os

/// Local-notification reminder for the active shopper. Fires after N seconds of no
/// cart activity so a shopper who wandered off / got distracted gets nudged to end
/// (or continue) the session.
///
/// The service is idempotent: `schedule(after:)` replaces any pending reminder with
/// a fresh one at the new delay; `cancel()` removes it. It sets itself as the
/// UNUserNotificationCenter delegate so the banner also shows if the app happens to
/// be foregrounded when the reminder fires.
final class ShopperReminderService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ShopperReminderService()

    private static let reminderIdentifier = "shopper.inactivity.reminder"
    private let logger = Logger(subsystem: "com.groceryapp", category: "ShopperReminder")
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    /// Ask for notification permission if we haven't yet. Safe to call repeatedly —
    /// the OS shows the prompt at most once.
    func requestPermissionIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("Notification auth request failed: \(error.localizedDescription)")
        }
    }

    /// Schedule the reminder to fire `delay` seconds from now, replacing any pending one.
    func schedule(after delay: TimeInterval) {
        cancel()

        let content = UNMutableNotificationContent()
        content.title = "Still shopping?"
        content.body = "Nothing crossed off in a while — tap Done Shopping when you're finished."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.reminderIdentifier,
            content: content,
            trigger: trigger
        )

        center.add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("Schedule reminder failed: \(error.localizedDescription)")
            }
        }
    }

    /// Cancel any pending shopper reminder.
    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderIdentifier])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even when the app is foreground so the shopper sees it.
        completionHandler([.banner, .sound])
    }
}
