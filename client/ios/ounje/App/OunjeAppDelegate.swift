import UIKit
import UserNotifications

/// UIKit delegate wired via `@UIApplicationDelegateAdaptor` so we can receive
/// the APNs device token. Without this bridge, SwiftUI's `App` lifecycle does
/// not expose the `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
/// callback.
final class OunjeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // We do not eagerly call registerForRemoteNotifications() here — the
        // user might decline notifications during onboarding and we don't want
        // to silently consume a token that we then drop. The notification
        // manager triggers registration only after the user grants permission.
        UNUserNotificationCenter.current().delegate = OunjeNotificationDelegate.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        OunjePushTokenRegistrar.shared.handleRegistered(tokenString: tokenString)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[APNs] registration failed:", error.localizedDescription)
    }

    /// Called when the app receives a remote notification while in the
    /// foreground. We forward to the notification center so any local
    /// follow-up (toast, badge update) happens consistently.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Notifications carry the app_notification_events row id so the
        // foreground experience can show the toast and mark it delivered.
        // Detailed handling lives in AppNotificationCenterManager.
        NotificationCenter.default.post(
            name: .ounjeRemoteNotificationReceived,
            object: nil,
            userInfo: userInfo
        )
        completionHandler(.newData)
    }
}

/// Foreground notification presentation: show the banner + play the sound so
/// the user sees important pushes (recipe-import-complete, autoshop-finished)
/// even while inside the app.
final class OunjeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OunjeNotificationDelegate()

    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        guard let url = Self.notificationURL(from: userInfo) else { return }
        OunjeNotificationDeepLinkBuffer.shared.store(url)
        NotificationCenter.default.post(
            name: .ounjeNotificationDeepLinkReceived,
            object: url,
            userInfo: ["url": url]
        )
    }

    private static func notificationURL(from userInfo: [AnyHashable: Any]) -> URL? {
        let keys = ["action_url", "actionURL", "deep_link", "deepLink"]
        for key in keys {
            if let rawValue = userInfo[key] as? String,
               let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
               !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return url
            }
        }
        return nil
    }
}

extension Notification.Name {
    /// Broadcast when the app receives a remote push while in the foreground.
    static let ounjeRemoteNotificationReceived = Notification.Name("ounjeRemoteNotificationReceived")
    /// Broadcast when the user taps a push/local notification with a destination.
    static let ounjeNotificationDeepLinkReceived = Notification.Name("ounjeNotificationDeepLinkReceived")
}

final class OunjeNotificationDeepLinkBuffer {
    static let shared = OunjeNotificationDeepLinkBuffer()

    private let storageKey = "ounje.notification.pendingDeepLink"

    private init() {}

    func store(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: storageKey)
    }

    func consume() -> URL? {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
              let url = URL(string: rawValue)
        else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: storageKey)
        return url
    }
}
