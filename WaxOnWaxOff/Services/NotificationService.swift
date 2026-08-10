import Foundation
import UserNotifications

enum NotificationService {
    static func showCompletionNotification(mode: AppMode, fileCount: Int) async {
        guard fileCount > 0 else { return }

        // Unit tests are hosted inside the app bundle, so this would otherwise
        // reach the real notification centre. On a machine that has never
        // answered the prompt — every fresh CI runner — `authorizationStatus`
        // is `.notDetermined`, `requestAuthorization` puts up a system dialog,
        // and with nobody to answer it the `await` below never returns. That
        // hangs the caller, not just the notification: `DeliveryViewModel`
        // awaits this before clearing `isProcessing`.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

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
            content.title = mode == .waxOn ? "WaxOn Processing Complete" : "WaxOff Delivery Complete"
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
