//
//  NotificationService.swift
//  rounds
//
//  Local notifications for when a background next-steps generation finishes with a change.
//  A delegate lets banners show even while Rounds is frontmost.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Install the delegate so notifications present (banner + sound) even in the foreground.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask the user to allow notifications. Returns whether it's authorized afterward.
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                cont.resume(returning: granted)
            }
        }
    }

    /// Post a notification — no-op unless the user authorized it.
    func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // Show banners while the app is frontmost too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
