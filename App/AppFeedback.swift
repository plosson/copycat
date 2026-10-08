import AppKit
import CopycatCore
import UserNotifications

/// Icon, sound and failure notification.
final class AppFeedback: NSObject, FeedbackSink, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private weak var model: AppModel?

    @MainActor
    init(model: AppModel) {
        self.model = model
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func working() {
        Task { @MainActor in model?.show(.working) }
    }

    func succeeded() {
        Task { @MainActor in
            model?.show(.succeeded)
            if model?.soundOn == true { NSSound(named: "Tink")?.play() }
        }
    }

    func failed(_ error: CopyError) {
        Task { @MainActor in model?.show(.failed) }
        let center = UNUserNotificationCenter.current()
        // Asks for permission the first time only; later calls return the stored answer.
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Copycat could not copy the file"
            content.body = error.message
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Show the banner even though Copycat counts as the active app while its menu is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
