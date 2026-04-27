import Foundation

@MainActor
final class AppModel {
    struct ListeningHistoryScanResult {
        let importedCount: Int
        let flushedPlaybackHistoryCount: Int

        var dialogCount: Int {
            if flushedPlaybackHistoryCount > 0 {
                return flushedPlaybackHistoryCount
            }
            return importedCount
        }
    }

    static let shared = AppModel()

    private enum Keys {
        static let lastBacklogFlushAt = "FastScrobbler.AppModel.lastBacklogFlushAt"
        static let hasSeenSetup = "FastScrobbler.Setup.hasSeen"
        static let lastEnteredBackgroundAt = "FastScrobbler.AppModel.lastEnteredBackgroundAt"
    }

    let auth: LastFMAuthManager
    let observer: AppleMusicNowPlayingObserver
    let engine: ScrobbleEngine
    let backlog: ScrobbleBacklog
    let scrobbleLog: ScrobbleLogStore

    private var startTask: Task<Void, Never>?

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

    func prepareForBackground() {
        let backgroundedAt = Date()
        UserDefaults.standard.set(backgroundedAt, forKey: Keys.lastEnteredBackgroundAt)
        LiveActivityManager.shared.recordEnteredBackground(at: backgroundedAt)
        observer.stop()
        engine.pauseForBackground()
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
            }
        }
        await engine.tickAsync()
    }

    /// Imports plays from Apple Music listening history (when supported) and flushes the backlog if signed in.
    @discardableResult
    func scanListeningHistory(maxItems: Int = 200) async -> ListeningHistoryScanResult {
        guard AppSettings.scrobbleListeningHistoryEnabled() else {
            await purgePlaybackHistoryBacklogIfNeeded()
            return ListeningHistoryScanResult(importedCount: 0, flushedPlaybackHistoryCount: 0)
        }

        let imported = await PlaybackHistoryImporter.shared.importIntoBacklog(
            backlog: backlog,
            scrobbleLog: scrobbleLog,
            maxItems: maxItems
        )

        guard let sessionKey = auth.sessionKey else {
            return ListeningHistoryScanResult(importedCount: imported, flushedPlaybackHistoryCount: 0)
        }

        let flushResult = await flushBacklogIfNeeded(sessionKey: sessionKey, force: true)
        let flushedPlaybackHistoryCount = flushResult.sentItems.reduce(into: 0) { count, item in
            if item.origin == .playbackHistory {
                count += 1
            }
        }

        return ListeningHistoryScanResult(
            importedCount: imported,
            flushedPlaybackHistoryCount: flushedPlaybackHistoryCount
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
