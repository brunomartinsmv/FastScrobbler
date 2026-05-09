import BackgroundTasks
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared.memoryCapacity = 0
        URLCache.shared.diskCapacity = 0

        // Ensure shared objects exist for background task launches (no UI scene).
        _ = AppModel.shared
        Task { @MainActor in
            await ICloudSyncCoordinator.shared.startIfNeeded()
            await ProPurchaseManager.shared.startIfNeeded()
        }
        BackgroundTaskManager.shared.registerIfNeeded()
        BackgroundTaskManager.shared.scheduleAppRefresh()
        BackgroundTaskManager.shared.scheduleProcessingIfNeeded()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        if #available(iOS 16.2, *) {
            Task { @MainActor in
                await LiveActivityManager.shared.stop()
            }
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
