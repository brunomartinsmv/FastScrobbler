import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AppModel {
    struct ListeningHistoryScanResult {
        let importedCount: Int
        let flushedPlaybackHistoryCount: Int
        let skippedDuplicateCount: Int
    }

    static let shared = AppModel()

    private enum Keys {
        static let lastBacklogFlushAt = "FastScrobbler.AppModel.lastBacklogFlushAt"
        static let hasSeenSetup = "FastScrobbler.Setup.hasSeen"
        static let lastEnteredBackgroundAt = "FastScrobbler.AppModel.lastEnteredBackgroundAt"
    }

    private enum ListeningHistoryScanLimits {
        static let maxImports = 1000
        static let maxFlushBatches = 80
    }

    private enum LiveBackgroundScrobbling {
        static let tickIntervalSeconds: TimeInterval = 4
        static let backlogFlushIntervalSeconds: TimeInterval = 30
        static let backgroundTimeSafetyMarginSeconds: TimeInterval = 2
        static let backgroundLastChanceWindowSeconds: TimeInterval = 18
        static let backgroundProjectionWindowSeconds: TimeInterval = 30
        static let inactivePlaybackToleranceSeconds: TimeInterval = 8
    }

    let auth: LastFMAuthManager
    let observer: AppleMusicNowPlayingObserver
    let engine: ScrobbleEngine
    let backlog: ScrobbleBacklog
    let scrobbleLog: ScrobbleLogStore

    private var startTask: Task<Void, Never>?
    private var liveBackgroundScrobbleTask: Task<Void, Never>?

    private init() {
        let auth = LastFMAuthManager()
        let observer = AppleMusicNowPlayingObserver()
        self.auth = auth
        self.observer = observer
        let backlog = ScrobbleBacklog.shared
        self.backlog = backlog
        let scrobbleLog = ScrobbleLogStore.shared
        self.scrobbleLog = scrobbleLog
        self.engine = ScrobbleEngine(auth: auth, observer: observer, backlog: backlog, scrobbleLog: scrobbleLog)
    }

    func startIfNeeded() {
        startTask?.cancel()
        startTask = Task { @MainActor in
            await self.performStart()
        }
    }

    private func performStart() async {
        guard UserDefaults.standard.bool(forKey: Keys.hasSeenSetup) else { return }

        if #available(iOS 16.2, *) {
            LiveActivityManager.shared.startIfPossible()
        }

        do {
            try await observer.start()
        } catch {
            await LiveActivityManager.shared.update(
                status: error.localizedDescription,
                track: nil,
                lastEventAt: Date(),
                isActivelyScrobbling: false,
                throttleSeconds: 0
            )
            return
        }
        guard !Task.isCancelled else { return }

        await backlog.cleanupNow()
        await purgePlaybackHistoryBacklogIfNeeded()

        if auth.sessionKey == nil {
            await LiveActivityManager.shared.update(
                status: NSLocalizedString("Connect Last.fm to scrobble.", comment: ""),
                track: observer.track,
                lastEventAt: Date(),
                isActivelyScrobbling: false,
                throttleSeconds: 0
            )
            return
        }

        if let sessionKey = auth.sessionKey {
            await auth.refreshUserInfoIfNeeded()
            let imported = await PlaybackHistoryImporter.shared.importIntoBacklog(
                backlog: backlog,
                scrobbleLog: scrobbleLog,
                maxItems: 200
            )
            UserDefaults.standard.removeObject(forKey: Keys.lastEnteredBackgroundAt)
            await flushBacklogIfNeeded(sessionKey: sessionKey, force: imported > 0)
            BackgroundTaskManager.shared.scheduleProcessingIfNeeded()
        }

        // Foreground transitions can leave Timers paused or invalidated.
        engine.start()

        // Ensure the app immediately re-sync state on foreground transitions (Timers pause while backgrounded).
        await engine.tickAsync()
    }

    func handleSceneDidBecomeActive() async {
        guard UserDefaults.standard.bool(forKey: Keys.hasSeenSetup) else { return }

        if #available(iOS 16.2, *) {
            await LiveActivityManager.shared.handleAppBecameActive()
        }
    }

    func handleWillEnterForeground() {
        stopLiveBackgroundScrobbleLoop()
        BackgroundTaskManager.shared.endLiveScrobbleGracePeriod()
        observer.resumePolling()
        UserDefaults.standard.removeObject(forKey: Keys.lastEnteredBackgroundAt)
        if #available(iOS 16.2, *) {
            LiveActivityManager.shared.clearEnteredBackground()
        }
    }

    func prepareForBackground() {
        let backgroundedAt = Date()
        UserDefaults.standard.set(backgroundedAt, forKey: Keys.lastEnteredBackgroundAt)
        LiveActivityManager.shared.recordEnteredBackground(at: backgroundedAt)
        stopLiveBackgroundScrobbleLoop()

        let shouldKeepLiveScrobbling =
            UserDefaults.standard.bool(forKey: Keys.hasSeenSetup) &&
            auth.sessionKey != nil &&
            !engine.isUserPaused &&
            engine.isRunning &&
            observer.isRunning &&
            observer.track != nil &&
            observer.playbackState == .playing

        if shouldKeepLiveScrobbling {
            let started = BackgroundTaskManager.shared.startLiveScrobbleGracePeriod { [weak self] in
                await self?.finishBackgroundGracePeriodIfNeeded()
            }
            if !started {
                observer.suspendPolling()
                engine.pauseForBackground()
            } else {
                observer.suspendPolling()
                engine.pauseForBackground()
                Task { @MainActor [weak self] in
                    await self?.performImmediateBackgroundScrobbleCheck()
                }
                startLiveBackgroundScrobbleLoop()
            }
        } else {
            observer.suspendPolling()
            engine.pauseForBackground()
        }

        Task { @MainActor in
            if #available(iOS 16.2, *) {
                await LiveActivityManager.shared.scheduleDismissalAfterAppClosed(backgroundedAt: backgroundedAt)
            }
        }
    }

    func finishBackgroundGracePeriodIfNeeded() async {
        guard UserDefaults.standard.object(forKey: Keys.lastEnteredBackgroundAt) != nil else { return }

        stopLiveBackgroundScrobbleLoop()
        await engine.tickAsync()
        engine.pauseForBackground()
        BackgroundTaskManager.shared.scheduleAppRefresh()
        BackgroundTaskManager.shared.scheduleProcessingIfNeeded()
    }

    private func performImmediateBackgroundScrobbleCheck() async {
        guard shouldContinueLiveBackgroundScrobbling() else { return }

        observer.refreshOnceIfAuthorized()
        await engine.tickAsync()
        BackgroundTaskManager.shared.recordLiveScrobbleGraceProjectionAttempt()
        _ = await engine.attemptProjectedBackgroundScrobble(
            maxProjectionSeconds: LiveBackgroundScrobbling.backgroundProjectionWindowSeconds
        )
    }

    private func startLiveBackgroundScrobbleLoop() {
        stopLiveBackgroundScrobbleLoop()

        liveBackgroundScrobbleTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var lastBacklogFlushAt = Date.distantPast
            var inactivePlaybackStartedAt: Date?

            while !Task.isCancelled {
                self.observer.refreshOnceIfAuthorized()

                let now = Date()
                if self.shouldContinueLiveBackgroundScrobbling() {
                    inactivePlaybackStartedAt = nil
                } else {
                    let inactiveStartedAt = inactivePlaybackStartedAt ?? now
                    inactivePlaybackStartedAt = inactiveStartedAt
                    guard now.timeIntervalSince(inactiveStartedAt) < LiveBackgroundScrobbling.inactivePlaybackToleranceSeconds else {
                        break
                    }
                }

                await self.engine.tickAsync()
                BackgroundTaskManager.shared.recordLiveScrobbleGraceProjectionAttempt()
                _ = await self.engine.attemptProjectedBackgroundScrobble(
                    maxProjectionSeconds: LiveBackgroundScrobbling.backgroundProjectionWindowSeconds
                )

                if now.timeIntervalSince(lastBacklogFlushAt) >= LiveBackgroundScrobbling.backlogFlushIntervalSeconds,
                   let sessionKey = self.auth.sessionKey {
                    await self.flushBacklogIfNeeded(sessionKey: sessionKey)
                    lastBacklogFlushAt = now
                }

                let remainingBackgroundTime = BackgroundTaskManager.shared.liveScrobbleBackgroundTimeRemaining
                if remainingBackgroundTime.isFinite,
                   remainingBackgroundTime <= LiveBackgroundScrobbling.backgroundLastChanceWindowSeconds {
                    let renewed = BackgroundTaskManager.shared.attemptLiveScrobbleGraceRenewalIfAllowed()

                    if !renewed,
                       remainingBackgroundTime <= LiveBackgroundScrobbling.backgroundTimeSafetyMarginSeconds {
                        await BackgroundTaskManager.shared.expireLiveScrobbleGracePeriodBecauseBackgroundTimeIsNearlyExhausted(
                            remaining: remainingBackgroundTime
                        )
                        return
                    }
                }

                let currentRemainingBackgroundTime = BackgroundTaskManager.shared.liveScrobbleBackgroundTimeRemaining
                if currentRemainingBackgroundTime.isFinite,
                   currentRemainingBackgroundTime <= LiveBackgroundScrobbling.backgroundTimeSafetyMarginSeconds {
                    await BackgroundTaskManager.shared.expireLiveScrobbleGracePeriodBecauseBackgroundTimeIsNearlyExhausted(
                        remaining: currentRemainingBackgroundTime
                    )
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: UInt64(LiveBackgroundScrobbling.tickIntervalSeconds * 1_000_000_000))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            await BackgroundTaskManager.shared.expireLiveScrobbleGracePeriodBecausePlaybackIsNoLongerActive()
        }
    }

    private func stopLiveBackgroundScrobbleLoop() {
        liveBackgroundScrobbleTask?.cancel()
        liveBackgroundScrobbleTask = nil
    }

    private func shouldContinueLiveBackgroundScrobbling() -> Bool {
        UserDefaults.standard.bool(forKey: Keys.hasSeenSetup) &&
            auth.sessionKey != nil &&
            !engine.isUserPaused &&
            engine.isRunning &&
            observer.isRunning &&
            observer.track != nil &&
            observer.playbackState == .playing
    }

    func backgroundTick() async {
        guard UserDefaults.standard.bool(forKey: Keys.hasSeenSetup) else { return }

        observer.refreshOnceIfAuthorized()
        await purgePlaybackHistoryBacklogIfNeeded()
        _ = await PlaybackHistoryImporter.shared.importIntoBacklog(backlog: backlog, scrobbleLog: scrobbleLog)
        if let sessionKey = auth.sessionKey {
            let result = await backlog.flush(sessionKey: sessionKey)
            for item in result.sentItems {
                scrobbleLog.record(
                    track: item.track,
                    startTimestamp: item.startTimestamp,
                    scrobbledAt: item.scrobbledAt,
                    source: scrobbleLogSource(for: item.origin),
                    lovedOnLastFM: item.lovedOnLastFM
                )
                AppReviewManager.shared.recordSuccessfulScrobble()
            }
        }
        await engine.tickAsync()
    }

    /// Imports plays from Apple Music listening history (when supported) and flushes the backlog if signed in.
    @discardableResult
    func scanListeningHistory(maxItems: Int = 200, allowExtendedLookback: Bool = false) async -> ListeningHistoryScanResult {
        guard AppSettings.scrobbleListeningHistoryEnabled() else {
            await purgePlaybackHistoryBacklogIfNeeded()
            return ListeningHistoryScanResult(importedCount: 0, flushedPlaybackHistoryCount: 0, skippedDuplicateCount: 0)
        }

        let extendedLookback = allowExtendedLookback && AppSettings.extendedListeningHistoryScanEnabled()
        var totalImported = 0
        var totalSkippedDuplicates = 0
        if maxItems > 0 {
            while totalImported < ListeningHistoryScanLimits.maxImports {
                if Task.isCancelled { break }

                let batchLimit = min(maxItems, ListeningHistoryScanLimits.maxImports - totalImported)
                let importResult = await PlaybackHistoryImporter.shared.importIntoBacklogDetailed(
                    backlog: backlog,
                    scrobbleLog: scrobbleLog,
                    maxItems: batchLimit,
                    mode: .recentBackfill(extendedLookback: extendedLookback)
                )
                let imported = importResult.importedCount
                totalSkippedDuplicates += importResult.skippedDuplicateCount

                guard imported > 0 else { break }
                totalImported += imported
            }
        }

        guard let sessionKey = auth.sessionKey else {
            return ListeningHistoryScanResult(
                importedCount: totalImported,
                flushedPlaybackHistoryCount: 0,
                skippedDuplicateCount: totalSkippedDuplicates
            )
        }

        var totalFlushedPlaybackHistoryCount = 0
        for _ in 0..<ListeningHistoryScanLimits.maxFlushBatches {
            if Task.isCancelled { break }

            let flushResult = await flushBacklogIfNeeded(sessionKey: sessionKey, force: true)
            let flushedPlaybackHistoryCount = flushResult.sentItems.reduce(into: 0) { count, item in
                if item.origin == .playbackHistory {
                    count += 1
                }
            }

            guard flushedPlaybackHistoryCount > 0 else { break }
            totalFlushedPlaybackHistoryCount += flushedPlaybackHistoryCount
        }

        return ListeningHistoryScanResult(
            importedCount: totalImported,
            flushedPlaybackHistoryCount: totalFlushedPlaybackHistoryCount,
            skippedDuplicateCount: totalSkippedDuplicates
        )
    }

    func handleListeningHistoryScrobblingChanged(isEnabled: Bool) async {
        guard !isEnabled else { return }
        await backlog.removeAll(origin: .playbackHistory)
    }

    func periodicFlush() async {
        guard let sessionKey = auth.sessionKey else { return }
        await flushBacklogIfNeeded(sessionKey: sessionKey)
    }

    @discardableResult
    private func flushBacklogIfNeeded(sessionKey: String, force: Bool = false) async -> ScrobbleBacklog.FlushResult {
        let pending = await backlog.pendingCount()
        guard pending > 0 else {
            return ScrobbleBacklog.FlushResult(sentCount: 0, skippedCount: 0, remainingCount: 0, sentItems: [])
        }

        let now = Date()
        if !force {
            let lastFlush = UserDefaults.standard.object(forKey: Keys.lastBacklogFlushAt) as? Date
            if let lastFlush, now.timeIntervalSince(lastFlush) < 60 {
                return ScrobbleBacklog.FlushResult(
                    sentCount: 0,
                    skippedCount: 0,
                    remainingCount: pending,
                    sentItems: []
                )
            }
        }

        UserDefaults.standard.set(now, forKey: Keys.lastBacklogFlushAt)

        let result = await backlog.flush(sessionKey: sessionKey)
        for item in result.sentItems {
            scrobbleLog.record(
                track: item.track,
                startTimestamp: item.startTimestamp,
                scrobbledAt: item.scrobbledAt,
                source: scrobbleLogSource(for: item.origin),
                lovedOnLastFM: item.lovedOnLastFM
            )
            AppReviewManager.shared.recordSuccessfulScrobble()
        }
        return result
    }

    private func purgePlaybackHistoryBacklogIfNeeded() async {
        guard !AppSettings.scrobbleListeningHistoryEnabled() else { return }
        await backlog.removeAll(origin: .playbackHistory)
    }

    private func scrobbleLogSource(for origin: ScrobbleBacklog.Origin?) -> ScrobbleLogStore.Source {
        switch origin {
        case .playbackHistory:
            return .playbackHistory
        case .recentlyPlayed:
            return .recentlyPlayed
        case .manual:
            return .manual
        case .live, .none:
            return .backlog
        }
    }
}

@MainActor
final class AppReviewManager {
    static let shared = AppReviewManager()

    private enum Keys {
        static let firstLaunchAt = "FastScrobbler.Review.firstLaunchAt"
        static let lastCountedSessionAt = "FastScrobbler.Review.lastCountedSessionAt"
        static let engagedSessionCount = "FastScrobbler.Review.engagedSessionCount"
        static let successfulScrobbleCount = "FastScrobbler.Review.successfulScrobbleCount"
        static let lastPromptedVersion = "FastScrobbler.Review.lastPromptedVersion"
        static let hasSeenSetup = "FastScrobbler.Setup.hasSeen"
    }

    private let defaults = UserDefaults.standard
    private let minimumDaysSinceFirstLaunch: TimeInterval = 7 * 24 * 60 * 60
    private let minimumSessionSpacing: TimeInterval = 4 * 60 * 60
    private let minimumEngagedSessions = 4
    private let minimumSuccessfulScrobbles = 10

    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6759501541?action=write-review")!

    private init() {
        if defaults.object(forKey: Keys.firstLaunchAt) == nil {
            defaults.set(Date(), forKey: Keys.firstLaunchAt)
        }
    }

    #if canImport(UIKit)
    func recordAppDidBecomeActive(in windowScene: UIWindowScene) {
        if defaults.object(forKey: Keys.firstLaunchAt) == nil {
            defaults.set(Date(), forKey: Keys.firstLaunchAt)
        }

        guard defaults.bool(forKey: Keys.hasSeenSetup) else { return }

        let now = Date()
        if let lastCountedSessionAt = defaults.object(forKey: Keys.lastCountedSessionAt) as? Date {
            if now.timeIntervalSince(lastCountedSessionAt) >= minimumSessionSpacing {
                defaults.set(now, forKey: Keys.lastCountedSessionAt)
                defaults.set(defaults.integer(forKey: Keys.engagedSessionCount) + 1, forKey: Keys.engagedSessionCount)
            }
        } else {
            defaults.set(now, forKey: Keys.lastCountedSessionAt)
            defaults.set(1, forKey: Keys.engagedSessionCount)
        }

        requestReviewIfEligible(in: windowScene, now: now)
    }
    #endif

    func recordSuccessfulScrobble() {
        defaults.set(defaults.integer(forKey: Keys.successfulScrobbleCount) + 1, forKey: Keys.successfulScrobbleCount)
    }

    #if canImport(UIKit)
    private func requestReviewIfEligible(in windowScene: UIWindowScene, now: Date) {
        guard let firstLaunchAt = defaults.object(forKey: Keys.firstLaunchAt) as? Date else { return }
        guard now.timeIntervalSince(firstLaunchAt) >= minimumDaysSinceFirstLaunch else { return }
        guard defaults.integer(forKey: Keys.engagedSessionCount) >= minimumEngagedSessions else { return }
        guard defaults.integer(forKey: Keys.successfulScrobbleCount) >= minimumSuccessfulScrobbles else { return }

        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let currentVersion, !currentVersion.isEmpty else { return }
        guard defaults.string(forKey: Keys.lastPromptedVersion) != currentVersion else { return }

        defaults.set(currentVersion, forKey: Keys.lastPromptedVersion)
        SKStoreReviewController.requestReview(in: windowScene)
    }
    #endif
}
