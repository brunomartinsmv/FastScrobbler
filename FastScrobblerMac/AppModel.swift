import Foundation

@MainActor
final class PermissionStatusStore: ObservableObject {
    @Published private(set) var mediaLibraryStatus: MPMediaLibraryAuthorizationStatus = MPMediaLibrary.authorizationStatus()
    @Published private(set) var automationStatus: MPMediaLibraryAuthorizationStatus = .notDetermined

    private var monitoringTask: Task<Void, Never>?

    func startMonitoring(observer: AppleMusicNowPlayingObserver) {
        monitoringTask?.cancel()
        monitoringTask = Task { @MainActor in
            await refreshNow(observer: observer)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { break }
                await refreshNow(observer: observer)
            }
        }
    }

    func refreshNow(observer: AppleMusicNowPlayingObserver) async {
        mediaLibraryStatus = MPMediaLibrary.authorizationStatus()
        automationStatus = await observer.refreshAuthorizationStatus()
    }
}

@MainActor
final class AppModel {
    static let shared = AppModel()

    private enum Keys {
        static let lastBacklogFlushAt = "FastScrobbler.AppModel.lastBacklogFlushAt"
        static let hasSeenSetup = "FastScrobbler.Setup.hasSeen"
        static let lastEnteredBackgroundAt = "FastScrobbler.AppModel.lastEnteredBackgroundAt"
        static let storageMigrationVersion = "FastScrobbler.StorageMaintenance.migrationVersion"
    }

    let auth: LastFMAuthManager
    let observer: AppleMusicNowPlayingObserver
    let engine: ScrobbleEngine
    let backlog: ScrobbleBacklog
    let scrobbleLog: ScrobbleLogStore
    let permissions: PermissionStatusStore

    private var startTask: Task<Void, Never>?

    private init() {
        let auth = LastFMAuthManager()
        let observer = AppleMusicNowPlayingObserver()
        self.auth = auth
        self.observer = observer
        let permissions = PermissionStatusStore()
        self.permissions = permissions
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
        await runStorageMaintenanceIfNeeded()
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
            UserDefaults.standard.removeObject(forKey: Keys.lastEnteredBackgroundAt)
            await flushBacklogIfNeeded(sessionKey: sessionKey)
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

    func handleListeningHistoryScrobblingChanged(isEnabled: Bool) async {
        guard !isEnabled else { return }
        await backlog.removeAll(origin: .playbackHistory)
    }

    func periodicFlush() async {
        guard let sessionKey = auth.sessionKey else { return }
        await flushBacklogIfNeeded(sessionKey: sessionKey)
    }

    func runStorageMaintenanceNow() async {
        await backlog.cleanupNow()
        scrobbleLog.cleanupNow()
    }

    func collectStorageUsageSnapshot() async -> StorageUsageSnapshot {
        StorageUsageSnapshot(
            backlogCount: await backlog.pendingCount(),
            backlogBytes: await backlog.storageSizeBytes(),
            scrobbleLogCount: scrobbleLog.entries.count,
            scrobbleLogBytes: scrobbleLog.storageSizeBytes(),
            playbackHistoryStateBytes: 0,
            recentTracksStateBytes: 0
        )
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
        }
        return result
    }

    private func purgePlaybackHistoryBacklogIfNeeded() async {
        guard !AppSettings.scrobbleListeningHistoryEnabled() else { return }
        await backlog.removeAll(origin: .playbackHistory)
    }

    private func runStorageMaintenanceIfNeeded() async {
        let currentMigrationVersion = 1
        let storedVersion = AppGroup.userDefaults.integer(forKey: Keys.storageMigrationVersion)
        guard storedVersion < currentMigrationVersion else { return }
        await runStorageMaintenanceNow()
        AppGroup.userDefaults.set(currentMigrationVersion, forKey: Keys.storageMigrationVersion)
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
