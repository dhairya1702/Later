import UIKit

final class LaterAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults(suiteName: ShareInboxConfiguration.appGroup)
        defaults?.set(token, forKey: ShareInboxConfiguration.pushTokenKey)
        #if DEBUG
        defaults?.set("sandbox", forKey: ShareInboxConfiguration.apnsEnvironmentKey)
        #else
        defaults?.set("production", forKey: ShareInboxConfiguration.apnsEnvironmentKey)
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Local reminders remain available if APNs registration is unavailable.
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == ShareAnalysisUploadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        ShareAnalysisUploadManager.shared.handleEvents(completionHandler: completionHandler)
    }
}
