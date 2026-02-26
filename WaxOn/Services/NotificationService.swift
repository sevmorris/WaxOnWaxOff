import Foundation
import UserNotifications

enum NotificationService {
    static func showCompletionNotification(fileCount: Int) async {
        let center = UNUserNotificationCenter.current()

        do {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }
            case .authorized, .provisional:
                break
            default:
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "WaxOn Processing Complete"
            content.body = "Successfully processed \(fileCount) file\(fileCount == 1 ? "" : "s")"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )

            try await center.add(request)
        } catch {
            // Notification failed silently
        }
    }
}
