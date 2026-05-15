import Foundation
import UIKit

/// Forwards APNs device tokens to the Ounje backend.
///
/// Flow:
///   1. User grants notification permission → `AppNotificationCenterManager`
///      calls `UIApplication.shared.registerForRemoteNotifications()`.
///   2. iOS asynchronously delivers the token to `OunjeAppDelegate`.
///   3. The delegate calls `handleRegistered(tokenString:)` which caches the
///      token and (if we already have an authenticated session) posts it to
///      `/v1/push-tokens/register`.
///   4. When the user signs in later or refreshes their session, the cached
///      token is replayed via `registerCurrentTokenIfPossible(session:)`.
///
/// We never call APNs registration eagerly on cold launch; the token only
/// lands here after the user has opted in.
@MainActor
final class OunjePushTokenRegistrar {
    static let shared = OunjePushTokenRegistrar()

    private init() {}

    private let tokenStorageKey = "ounje.apns.deviceToken"
    private let lastRegisteredSessionKey = "ounje.apns.lastRegisteredSessionUserID"
    private let lastRegisteredAtKey = "ounje.apns.lastRegisteredAt"
    private let registrationRefreshInterval: TimeInterval = 6 * 60 * 60

    /// Provides the current AuthSession when the registrar needs to ship a
    /// token. Wired by `OunjeAppScene` so we don't have to import the full
    /// store into the registrar's module.
    var sessionProvider: (() async -> AuthSession?)?

    private var pendingTokenString: String?

    /// Called by `OunjeAppDelegate` when iOS delivers the device token.
    nonisolated func handleRegistered(tokenString: String) {
        Task { @MainActor in
            await persistAndPostIfReady(tokenString: tokenString)
        }
    }

    /// Called after sign-in / sign-back-in. Replays the last cached token so
    /// the server's `device_tokens` row is associated with the new user_id.
    func registerCurrentTokenIfPossible(session: AuthSession?, force: Bool = false) {
        guard let session else { return }
        let cached = pendingTokenString ?? UserDefaults.standard.string(forKey: tokenStorageKey)
        guard let token = cached, !token.isEmpty else { return }
        let lastUserID = UserDefaults.standard.string(forKey: lastRegisteredSessionKey)
        let lastRegisteredAt = UserDefaults.standard.object(forKey: lastRegisteredAtKey) as? Date
        if !force,
           lastUserID == session.userID,
           let lastRegisteredAt,
           Date().timeIntervalSince(lastRegisteredAt) < registrationRefreshInterval {
            // Recently registered for this user; avoid a redundant POST while
            // still periodically reasserting the token if the backend row drifts.
            return
        }
        Task { await post(token: token, session: session) }
    }

    @discardableResult
    func registerCurrentTokenIfPossibleNow(session: AuthSession?, force: Bool = false) async -> Bool {
        guard let session else { return false }
        let cached = pendingTokenString ?? UserDefaults.standard.string(forKey: tokenStorageKey)
        guard let token = cached, !token.isEmpty else { return false }
        let lastUserID = UserDefaults.standard.string(forKey: lastRegisteredSessionKey)
        let lastRegisteredAt = UserDefaults.standard.object(forKey: lastRegisteredAtKey) as? Date
        if !force,
           lastUserID == session.userID,
           let lastRegisteredAt,
           Date().timeIntervalSince(lastRegisteredAt) < registrationRefreshInterval {
            return true
        }
        return await post(token: token, session: session)
    }

    private func persistAndPostIfReady(tokenString: String) async {
        pendingTokenString = tokenString
        UserDefaults.standard.set(tokenString, forKey: tokenStorageKey)

        guard let session = await sessionProvider?(),
              !session.userID.isEmpty,
              !(session.accessToken ?? "").isEmpty
        else { return }
        _ = await post(token: tokenString, session: session)
    }

    @discardableResult
    private func post(token: String, session: AuthSession) async -> Bool {
        let environment: String
        #if DEBUG
        environment = "sandbox"
        #else
        environment = "production"
        #endif

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let payload: [String: Any] = [
            "token": token,
            "environment": environment,
            "platform": UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "ios",
            "app_version": appVersion ?? "",
            "device_model": UIDevice.current.model,
            "os_version": UIDevice.current.systemVersion
        ]

        guard let url = URL(string: "\(OunjeDevelopmentServer.primaryBaseURL)/v1/push-tokens/register") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken = session.accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) {
                UserDefaults.standard.set(session.userID, forKey: lastRegisteredSessionKey)
                UserDefaults.standard.set(Date(), forKey: lastRegisteredAtKey)
                return true
            } else if let http = response as? HTTPURLResponse {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[APNs] /v1/push-tokens/register returned \(http.statusCode):", body)
            }
        } catch {
            print("[APNs] /v1/push-tokens/register failed:", error.localizedDescription)
        }
        return false
    }

    /// Called on sign-out so we don't leave a stale (user_id, token) row
    /// active after the user gives up the device. The server endpoint
    /// deletes the row.
    func unregisterCurrentToken(session: AuthSession?) {
        guard let session else { return }
        let token = pendingTokenString ?? UserDefaults.standard.string(forKey: tokenStorageKey)
        guard let token, !token.isEmpty,
              !(session.accessToken ?? "").isEmpty else { return }
        Task { await postUnregister(token: token, session: session) }
        UserDefaults.standard.removeObject(forKey: lastRegisteredSessionKey)
        UserDefaults.standard.removeObject(forKey: lastRegisteredAtKey)
    }

    private func postUnregister(token: String, session: AuthSession) async {
        guard let url = URL(string: "\(OunjeDevelopmentServer.primaryBaseURL)/v1/push-tokens/unregister") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken = session.accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }
}
