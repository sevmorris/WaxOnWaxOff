import Foundation
import UserNotifications

enum NotificationService {
    /// Post a completion notification. Returns immediately; the notification is
    /// delivered on its own task.
    ///
    /// Deliberately **not** `async`, and the permission prompt is why. On a Mac
    /// that has not yet answered it, `authorizationStatus` is `.notDetermined`
    /// and `requestAuthorization` does not return until the user responds. Every
    /// caller awaited this immediately before clearing `isProcessing`, so on a
    /// first run the toolbar went on showing a running batch — Cancel and all —
    /// until the prompt was dismissed, and the prompt is easy not to connect to
    /// the app you thought had just finished. Nothing downstream depends on the
    /// notification having been posted, so nothing should wait for it.
    ///
    /// Making the signature synchronous is the point: a future call site cannot
    /// reintroduce the block by forgetting to detach it.
    static func showCompletionNotification(mode: AppMode, fileCount: Int) {
        guard fileCount > 0 else { return }

        // Unit tests are hosted inside the app bundle, so this would otherwise
        // reach the real notification center. Since the call no longer blocks
        // its caller, this no longer prevents a hang — it stops a test run from
        // posting real notifications and from leaving an unanswerable prompt
        // behind on whatever machine ran it.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        Task { await deliver(mode: mode, fileCount: fileCount) }
    }

    private static func deliver(mode: AppMode, fileCount: Int) async {
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
