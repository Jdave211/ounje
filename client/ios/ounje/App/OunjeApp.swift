import SwiftUI

@main
struct OunjeAgenticApp: App {
    // Adopt the UIKit app delegate so we can receive the APNs device token
    // delivered via `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    // Without this, the SwiftUI lifecycle never exposes that callback.
    @UIApplicationDelegateAdaptor(OunjeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            OunjeAppScene()
        }
    }
}
