import UIKit
import UserNotifications

/// UIKit delegate wired via `@UIApplicationDelegateAdaptor` so we can receive
/// the APNs device token. Without this bridge, SwiftUI's `App` lifecycle does
/// not expose the `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
/// callback.
final class OunjeAppDelegate: NSObject, UIApplicationDelegate {
    private var shareImportBackgroundDelegates: [String: OunjeShareImportBackgroundSessionDelegate] = [:]

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // We do not eagerly call registerForRemoteNotifications() here — the
        // user might decline notifications during onboarding and we don't want
        // to silently consume a token that we then drop. The notification
        // manager triggers registration only after the user grants permission.
        UNUserNotificationCenter.current().delegate = OunjeNotificationDelegate.shared

        // The default URLCache is ~512 KB memory / 10 MB disk — far too small
        // for recipe card images. Raise it so images survive tab switches and
        // short backgrounding without re-downloading.
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,   // 50 MB in-process
            diskCapacity: 200 * 1024 * 1024,     // 200 MB on disk
            diskPath: "ounje-image-cache"
        )

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

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier.hasPrefix("net.ounje.share-import.") else {
            completionHandler()
            return
        }

        let delegate = OunjeShareImportBackgroundSessionDelegate { [weak self] in
            completionHandler()
            self?.shareImportBackgroundDelegates.removeValue(forKey: identifier)
            NotificationCenter.default.post(name: .recipeImportHistoryNeedsRefresh, object: nil)
        }
        shareImportBackgroundDelegates[identifier] = delegate

        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = SharedRecipeImportConstants.appGroupID
        configuration.sessionSendsLaunchEvents = true
        _ = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

private final class OunjeShareImportBackgroundSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, URLSessionDelegate {
    private let completionHandler: () -> Void
    private var responseDataByTaskID: [Int: Data] = [:]

    init(completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseDataByTaskID[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            responseDataByTaskID[task.taskIdentifier] = nil
        }

        let envelopeID = backgroundImportEnvelopeID(for: task, session: session)

        if let error {
            print("[ShareImportBackground] upload failed:", error.localizedDescription)
            requeueBackgroundImport(envelopeID: envelopeID, message: error.localizedDescription)
            return
        }

        guard let envelopeID else {
            return
        }

        guard let response = task.response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode) else {
            print("[ShareImportBackground] upload returned non-success status")
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode
            let message = statusCode.map { "Server rejected import handoff (\($0))." }
                ?? "Import handoff did not receive a server response."
            requeueBackgroundImport(envelopeID: envelopeID, message: message)
            return
        }

        guard let data = responseDataByTaskID[task.taskIdentifier], !data.isEmpty else {
            print("[ShareImportBackground] upload completed without response body")
            requeueBackgroundImport(
                envelopeID: envelopeID,
                message: "Import handoff completed without a server acknowledgement."
            )
            return
        }

        do {
            let importResponse = try JSONDecoder().decode(RecipeImportResponse.self, from: data)
            try reconcileBackgroundImport(envelopeID: envelopeID, response: importResponse)
        } catch {
            print("[ShareImportBackground] response reconciliation failed:", error.localizedDescription)
            requeueBackgroundImport(envelopeID: envelopeID, message: error.localizedDescription)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completionHandler()
    }

    private func reconcileBackgroundImport(envelopeID: String, response: RecipeImportResponse) throws {
        let localEnvelope = (try? SharedRecipeImportInbox.readAll().first { $0.id == envelopeID })
        let backendEnvelope = response.job.sharedImportEnvelope
        let envelope = localEnvelope ?? backendEnvelope
        let backendState = response.job.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let liveBackendStates: Set<String> = ["queued", "submitted", "retryable", "processing", "fetching", "parsing", "normalized"]
        let localState = liveBackendStates.contains(backendState) ? backendState : (backendState.isEmpty ? "queued" : backendState)
        let canonicalURL = [
            response.recipeDetail?.originalRecipeURLString,
            response.recipeDetail?.recipeURLString,
            response.job.canonicalURL,
            response.job.sourceURL,
            envelope.canonicalSourceURLString
        ]
        .compactMap { raw -> String? in
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        .first

        let updatedEnvelope = SharedRecipeImportEnvelope(
            id: envelope.id,
            createdAt: envelope.createdAt,
            jobID: response.job.id,
            targetState: envelope.targetState,
            sourceText: envelope.sourceText,
            sourceURLString: envelope.sourceURLString ?? response.job.sourceURL,
            canonicalSourceURLString: canonicalURL,
            sourceApp: envelope.sourceApp,
            attachments: envelope.attachments,
            processingState: localState,
            attemptCount: response.job.attempts ?? envelope.attemptCount,
            lastAttemptAt: Date(),
            serverSubmittedAt: envelope.serverSubmittedAt ?? backendEnvelope.serverSubmittedAt ?? Date(),
            lastError: response.job.errorMessage ?? response.job.reviewReason ?? envelope.lastError,
            activeStage: response.job.activeStage,
            stageStartedAt: backendEnvelope.stageStartedAt,
            updatedAt: Date()
        )
        try SharedRecipeImportInbox.update(updatedEnvelope)
    }

    private func backgroundImportEnvelopeID(for task: URLSessionTask, session: URLSession) -> String? {
        let taskDescription = task.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !taskDescription.isEmpty {
            return taskDescription
        }

        let prefix = "net.ounje.share-import."
        guard let identifier = session.configuration.identifier,
              identifier.hasPrefix(prefix) else {
            return nil
        }
        let suffix = identifier.dropFirst(prefix.count)
        let envelopeID = suffix.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return envelopeID.isEmpty ? nil : envelopeID
    }

    private func requeueBackgroundImport(envelopeID: String?, message: String) {
        guard let envelopeID,
              let envelope = try? SharedRecipeImportInbox.readAll().first(where: { $0.id == envelopeID }) else {
            return
        }
        let acknowledgedJobID = envelope.jobID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard acknowledgedJobID.isEmpty else {
            return
        }

        let queuedEnvelope = SharedRecipeImportEnvelope(
            id: envelope.id,
            createdAt: envelope.createdAt,
            jobID: nil,
            targetState: envelope.targetState,
            sourceText: envelope.sourceText,
            sourceURLString: envelope.sourceURLString,
            canonicalSourceURLString: envelope.canonicalSourceURLString,
            sourceApp: envelope.sourceApp,
            attachments: envelope.attachments,
            processingState: "queued",
            attemptCount: envelope.attemptCount,
            lastAttemptAt: Date(),
            serverSubmittedAt: nil,
            lastError: message,
            updatedAt: Date()
        )
        try? SharedRecipeImportInbox.update(queuedEnvelope)
    }
}

/// Foreground notification presentation: suppress normal system banners while
/// the user is already in the app. The server APNs test is allowed through so
/// users can verify backend delivery without leaving Ounje.
final class OunjeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OunjeNotificationDelegate()

    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        NotificationCenter.default.post(
            name: .ounjeRemoteNotificationReceived,
            object: nil,
            userInfo: userInfo
        )
        let kind = String(describing: userInfo["kind"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if kind == "notification_test" || kind == "apns_test" {
            completionHandler([.banner, .list, .sound])
            return
        }
        completionHandler([])
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
