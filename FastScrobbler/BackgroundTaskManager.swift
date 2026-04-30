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

#if os(iOS)
private final class BackgroundTaskIdentifierBox: @unchecked Sendable {
    var value: UIBackgroundTaskIdentifier = .invalid
}
#endif

final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    private let logger = Logger(subsystem: "FastScrobbler", category: "BackgroundTasks")
    private var isRegistered = false
#if os(iOS)
    private static let liveScrobbleExpirationSafetyMarginSeconds: TimeInterval = 2
    private static let maxLiveScrobbleGraceRenewals = 2
    private static let minLiveScrobbleGraceRenewalIntervalSeconds: TimeInterval = 6
    private var liveScrobbleGraceTaskID: UIBackgroundTaskIdentifier = .invalid
    private var liveScrobbleGraceWatchdogTask: Task<Void, Never>?
    private var liveScrobbleGraceDidExpire = false
    private var liveScrobbleGraceRenewalCount = 0
    private var liveScrobbleGraceProjectionAttempted = false
    private var liveScrobbleGraceStartedAt: Date?
    private var liveScrobbleGraceRenewedAt: Date?
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
        liveScrobbleGraceRenewalCount = 0
        liveScrobbleGraceProjectionAttempted = false
        liveScrobbleGraceStartedAt = Date()
        liveScrobbleGraceRenewedAt = nil
        liveScrobbleGraceOnExpired = onExpired

        let taskIDBox = BackgroundTaskIdentifierBox()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "FastScrobbler.LiveScrobbleGrace") { [weak self] in
            self?.expireLiveScrobbleGracePeriodFromSystemExpiration(taskID: taskIDBox.value)
        }
        taskIDBox.value = taskID

        guard taskID != .invalid else {
            liveScrobbleGraceOnExpired = nil
            liveScrobbleGraceStartedAt = nil
            logger.warning("failed to start live scrobble grace period")
            return false
        }

        liveScrobbleGraceTaskID = taskID
        liveScrobbleGraceWatchdogTask = makeLiveScrobbleGraceWatchdogTask()

        logger.info("started live scrobble grace period")
        return true
    }

    @MainActor
    func endLiveScrobbleGracePeriod() {
        liveScrobbleGraceWatchdogTask?.cancel()
        liveScrobbleGraceWatchdogTask = nil
        liveScrobbleGraceOnExpired = nil
        liveScrobbleGraceDidExpire = false
        liveScrobbleGraceRenewalCount = 0
        liveScrobbleGraceProjectionAttempted = false
        liveScrobbleGraceStartedAt = nil
        liveScrobbleGraceRenewedAt = nil

        guard liveScrobbleGraceTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(liveScrobbleGraceTaskID)
        liveScrobbleGraceTaskID = .invalid
        logger.info("ended live scrobble grace period")
    }

    @MainActor
    func attemptLiveScrobbleGraceRenewalIfAllowed() -> Bool {
        guard liveScrobbleGraceTaskID != .invalid else { return false }
        guard !liveScrobbleGraceDidExpire else { return false }
        guard liveScrobbleGraceRenewalCount < Self.maxLiveScrobbleGraceRenewals else { return false }
        guard UIApplication.shared.applicationState != .active else { return false }

        let now = Date()
        if let liveScrobbleGraceRenewedAt,
           now.timeIntervalSince(liveScrobbleGraceRenewedAt) < Self.minLiveScrobbleGraceRenewalIntervalSeconds {
            return false
        }

        liveScrobbleGraceRenewalCount += 1

        let oldTaskID = liveScrobbleGraceTaskID
        UIApplication.shared.endBackgroundTask(oldTaskID)
        liveScrobbleGraceTaskID = .invalid

        let taskIDBox = BackgroundTaskIdentifierBox()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "FastScrobbler.LiveScrobbleGrace.Renewed") { [weak self] in
            self?.expireLiveScrobbleGracePeriodFromSystemExpiration(taskID: taskIDBox.value)
        }
        taskIDBox.value = taskID

        guard taskID != .invalid else {
            logger.warning("failed to renew live scrobble grace period")
            return false
        }

        liveScrobbleGraceTaskID = taskID
        liveScrobbleGraceRenewedAt = now

        liveScrobbleGraceWatchdogTask?.cancel()
        liveScrobbleGraceWatchdogTask = makeLiveScrobbleGraceWatchdogTask()

        let remaining = UIApplication.shared.backgroundTimeRemaining
        if remaining.isFinite {
            logger.info("renewed live scrobble grace period \(self.liveScrobbleGraceRenewalCount, privacy: .public)/\(Self.maxLiveScrobbleGraceRenewals, privacy: .public) (remaining: \(remaining, privacy: .public)s)")
        } else {
            logger.info("renewed live scrobble grace period \(self.liveScrobbleGraceRenewalCount, privacy: .public)/\(Self.maxLiveScrobbleGraceRenewals, privacy: .public)")
        }
        return true
    }

    @MainActor
    func recordLiveScrobbleGraceProjectionAttempt() {
        guard liveScrobbleGraceTaskID != .invalid else { return }
        liveScrobbleGraceProjectionAttempted = true
    }

    @MainActor
    func expireLiveScrobbleGracePeriodBecauseBackgroundTimeIsNearlyExhausted(remaining: TimeInterval? = nil) async {
        await expireLiveScrobbleGracePeriod(
            reason: "background time nearly exhausted",
            remainingBackgroundTime: remaining
        )
    }

    @MainActor
    func expireLiveScrobbleGracePeriodBecausePlaybackIsNoLongerActive() async {
        await expireLiveScrobbleGracePeriod(reason: "playback no longer active")
    }

    @MainActor
    var liveScrobbleBackgroundTimeRemaining: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }

    private func makeLiveScrobbleGraceWatchdogTask() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }

                guard let self else { return }
                let remaining = UIApplication.shared.backgroundTimeRemaining
                guard remaining.isFinite else { continue }
                guard remaining <= Self.liveScrobbleExpirationSafetyMarginSeconds else { continue }

                await self.expireLiveScrobbleGracePeriod(
                    reason: "background time nearly exhausted",
                    remainingBackgroundTime: remaining
                )
            }
        }
    }

    @MainActor
    private func expireLiveScrobbleGracePeriod(
        reason: StaticString,
        remainingBackgroundTime: TimeInterval? = nil
    ) async {
        guard liveScrobbleGraceTaskID != .invalid || liveScrobbleGraceOnExpired != nil else { return }
        guard !liveScrobbleGraceDidExpire else { return }

        liveScrobbleGraceDidExpire = true
        liveScrobbleGraceWatchdogTask?.cancel()
        liveScrobbleGraceWatchdogTask = nil

        let onExpired = liveScrobbleGraceOnExpired
        liveScrobbleGraceOnExpired = nil

        logLiveScrobbleGraceExpirationSummary(reason: reason, remainingBackgroundTime: remainingBackgroundTime)

        if liveScrobbleGraceTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(liveScrobbleGraceTaskID)
            liveScrobbleGraceTaskID = .invalid
        }

        await onExpired?()
        liveScrobbleGraceDidExpire = false
        liveScrobbleGraceRenewalCount = 0
        liveScrobbleGraceProjectionAttempted = false
        liveScrobbleGraceStartedAt = nil
        liveScrobbleGraceRenewedAt = nil
    }

    private func expireLiveScrobbleGracePeriodFromSystemExpiration(taskID: UIBackgroundTaskIdentifier) {
        guard taskID != .invalid else { return }
        guard liveScrobbleGraceTaskID == taskID else {
            UIApplication.shared.endBackgroundTask(taskID)
            return
        }
        guard !liveScrobbleGraceDidExpire else {
            UIApplication.shared.endBackgroundTask(taskID)
            liveScrobbleGraceTaskID = .invalid
            return
        }

        liveScrobbleGraceDidExpire = true
        liveScrobbleGraceWatchdogTask?.cancel()
        liveScrobbleGraceWatchdogTask = nil

        let onExpired = liveScrobbleGraceOnExpired
        liveScrobbleGraceOnExpired = nil

        let remaining = UIApplication.shared.backgroundTimeRemaining
        logLiveScrobbleGraceExpirationSummary(
            reason: "system expiration",
            remainingBackgroundTime: remaining.isFinite ? remaining : nil
        )
        UIApplication.shared.endBackgroundTask(taskID)
        liveScrobbleGraceTaskID = .invalid

        Task { @MainActor [weak self] in
            await onExpired?()
            self?.liveScrobbleGraceDidExpire = false
            self?.liveScrobbleGraceRenewalCount = 0
            self?.liveScrobbleGraceProjectionAttempted = false
            self?.liveScrobbleGraceStartedAt = nil
            self?.liveScrobbleGraceRenewedAt = nil
        }
    }

    private func logLiveScrobbleGraceExpirationSummary(
        reason: StaticString,
        remainingBackgroundTime: TimeInterval?
    ) {
        if let remainingBackgroundTime {
            logger.info(
                "expiring live scrobble grace period: \(reason, privacy: .public) (remaining: \(remainingBackgroundTime, privacy: .public)s, renewals: \(self.liveScrobbleGraceRenewalCount, privacy: .public)/\(Self.maxLiveScrobbleGraceRenewals, privacy: .public), projectionAttempted: \(self.liveScrobbleGraceProjectionAttempted, privacy: .public))"
            )
        } else {
            logger.info(
                "expiring live scrobble grace period: \(reason, privacy: .public) (renewals: \(self.liveScrobbleGraceRenewalCount, privacy: .public)/\(Self.maxLiveScrobbleGraceRenewals, privacy: .public), projectionAttempted: \(self.liveScrobbleGraceProjectionAttempted, privacy: .public))"
            )
        }
    }
#endif
}
