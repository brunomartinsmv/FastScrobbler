import BackgroundTasks
import Foundation
import OSLog
#if os(iOS)
import UIKit
#endif

enum BackgroundTaskIdentifiers {
    static var appRefresh: String {
        // Must match the value in `Info.plist` BGTaskSchedulerPermittedIdentifiers.
        (Bundle.main.bundleIdentifier ?? "com.example.FastScrobbler") + ".appRefresh"
    }

    static var processing: String {
        // Must match the value in `Info.plist` BGTaskSchedulerPermittedIdentifiers.
        (Bundle.main.bundleIdentifier ?? "com.example.FastScrobbler") + ".processing"
    }
}

final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    private let logger = Logger(subsystem: "FastScrobbler", category: "BackgroundTasks")
    private var isRegistered = false
#if os(iOS)
    private static let liveScrobbleGracePeriodSeconds: TimeInterval = 5 * 60
    private var liveScrobbleGraceTaskID: UIBackgroundTaskIdentifier = .invalid
    private var liveScrobbleGraceTimeoutTask: Task<Void, Never>?
    private var liveScrobbleGraceDidExpire = false
    private var liveScrobbleGraceOnExpired: (@MainActor () async -> Void)?
#endif

    private init() {}

    func registerIfNeeded() {
        guard !isRegistered else { return }
        isRegistered = true

        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskIdentifiers.appRefresh, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(task)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskIdentifiers.processing, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleProcessing(task)
        }
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskIdentifiers.appRefresh)
        request.earliestBeginDate = nil // Let iOS decide; don't impose extra delay

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTaskIdentifiers.appRefresh)
            try BGTaskScheduler.shared.submit(request)
            logger.debug("scheduled BGAppRefreshTask")
        } catch {
            logger.warning("failed to schedule BGAppRefreshTask: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        logger.info("BGAppRefreshTask handler fired")
        // Always reschedule, since iOS schedules are one-shot.
        scheduleAppRefresh()

        runBGTask(task, softTimeoutSeconds: 25) {
            await AppModel.shared.backgroundTick()
        }
    }

    func scheduleProcessingIfNeeded() {
        Task { @MainActor in
            let pending = await ScrobbleBacklog.shared.pendingCount()
            let hasActiveTrack = AppModel.shared.observer.track != nil
            if pending > 0 || hasActiveTrack {
                self.scheduleProcessing()
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTaskIdentifiers.processing)
            }
        }
    }

    func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskIdentifiers.processing)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nil // Let iOS decide; don't impose extra delay

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTaskIdentifiers.processing)
            try BGTaskScheduler.shared.submit(request)
            logger.debug("scheduled BGProcessingTask")
        } catch {
            logger.warning("failed to schedule BGProcessingTask: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleProcessing(_ task: BGProcessingTask) {
        logger.info("BGProcessingTask handler fired")
        // Always reschedule, since iOS schedules are one-shot.
        scheduleProcessingIfNeeded()

        runBGTask(task, softTimeoutSeconds: 120) {
            await AppModel.shared.backgroundTick()
        }
    }

    private func runBGTask(_ task: BGTask, softTimeoutSeconds: TimeInterval, work: @escaping @MainActor () async -> Void) {
        let workTask = Task { @MainActor in
            await work()
        }

        task.expirationHandler = {
            workTask.cancel()
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, softTimeoutSeconds) * 1_000_000_000))
                workTask.cancel()
            } catch {
                // Ignore cancellation.
            }
        }

        Task {
            _ = await workTask.result
            timeoutTask.cancel()
            let cancelled = workTask.isCancelled
            logger.info("BGTask completed — success: \(!cancelled)")
            task.setTaskCompleted(success: !cancelled)
        }
    }

#if os(iOS)
    @MainActor
    func startLiveScrobbleGracePeriod(onExpired: @escaping @MainActor () async -> Void) -> Bool {
        endLiveScrobbleGracePeriod()

        liveScrobbleGraceDidExpire = false
        liveScrobbleGraceOnExpired = onExpired

        let taskID = UIApplication.shared.beginBackgroundTask(withName: "FastScrobbler.LiveScrobbleGrace") { [weak self] in
            Task { @MainActor in
                await self?.expireLiveScrobbleGracePeriod(reason: "system expiration")
            }
        }

        guard taskID != .invalid else {
            liveScrobbleGraceOnExpired = nil
            logger.warning("failed to start live scrobble grace period")
            return false
        }

        liveScrobbleGraceTaskID = taskID
        liveScrobbleGraceTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.liveScrobbleGracePeriodSeconds * 1_000_000_000))
            } catch {
                return
            }

            await self?.expireLiveScrobbleGracePeriod(reason: "requested timeout")
        }

        logger.info("started live scrobble grace period")
        return true
    }

    @MainActor
    func endLiveScrobbleGracePeriod() {
        liveScrobbleGraceTimeoutTask?.cancel()
        liveScrobbleGraceTimeoutTask = nil
        liveScrobbleGraceOnExpired = nil
        liveScrobbleGraceDidExpire = false

        guard liveScrobbleGraceTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(liveScrobbleGraceTaskID)
        liveScrobbleGraceTaskID = .invalid
        logger.info("ended live scrobble grace period")
    }

    @MainActor
    private func expireLiveScrobbleGracePeriod(reason: StaticString) async {
        guard liveScrobbleGraceTaskID != .invalid else { return }
        guard !liveScrobbleGraceDidExpire else { return }

        liveScrobbleGraceDidExpire = true
        liveScrobbleGraceTimeoutTask?.cancel()
        liveScrobbleGraceTimeoutTask = nil

        let onExpired = liveScrobbleGraceOnExpired
        liveScrobbleGraceOnExpired = nil

        logger.info("expiring live scrobble grace period: \(reason, privacy: .public)")
        await onExpired?()

        if liveScrobbleGraceTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(liveScrobbleGraceTaskID)
            liveScrobbleGraceTaskID = .invalid
        }
        liveScrobbleGraceDidExpire = false
    }
#endif
}
