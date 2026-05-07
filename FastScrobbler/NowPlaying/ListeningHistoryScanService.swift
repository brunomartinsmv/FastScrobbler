import Foundation

@MainActor
enum ListeningHistoryScanService {
    enum PauseBehavior {
        case respectPause
        case allowSubmissionWhilePaused
    }

    struct Result {
        let importedCount: Int
        let importedRecentTrackCount: Int
        let flushedPlaybackHistoryCount: Int
        let flushedRecentTrackCount: Int
        let skippedDuplicateCount: Int
        let recentTracksAuthorizationUnavailable: Bool
        let recentTracksStatus: AppleMusicRecentTracksImporter.ImportStatus

        var totalImportedCount: Int {
            importedCount + importedRecentTrackCount
        }

        var totalFlushedCount: Int {
            flushedPlaybackHistoryCount + flushedRecentTrackCount
        }
    }

    private enum Limits {
        static let maxImports = 1000
        static let maxFlushBatches = 80
    }

    private enum Keys {
        static let lastBacklogFlushAt = "FastScrobbler.AppModel.lastBacklogFlushAt"
    }

    @discardableResult
    static func scan(
        backlog: ScrobbleBacklog,
        scrobbleLog: ScrobbleLogStore,
        sessionKey: String?,
        maxItems: Int = 200,
        allowExtendedLookback: Bool = false,
        bypassRecentTrackCooldown: Bool = false,
        isUserPaused: Bool = false,
        pauseBehavior: PauseBehavior = .respectPause,
        recordSuccessfulScrobble: (() -> Void)? = nil
    ) async -> Result {
        if !AppSettings.scrobbleListeningHistoryEnabled() {
            await backlog.removeAll(origin: .playbackHistory)
        }

        let extendedLookback = allowExtendedLookback && AppSettings.extendedListeningHistoryScanEnabled()
        var totalImported = 0
        var totalSkippedDuplicates = 0
        if maxItems > 0, AppSettings.scrobbleListeningHistoryEnabled() {
            while totalImported < Limits.maxImports {
                if Task.isCancelled { break }

                let batchLimit = min(maxItems, Limits.maxImports - totalImported)
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

        let recentImportResult = await AppleMusicRecentTracksImporter.shared.importIntoBacklog(
            backlog: backlog,
            scrobbleLog: scrobbleLog,
            maxItems: maxItems > 0 ? min(maxItems, 30) : 0,
            bypassCooldown: bypassRecentTrackCooldown
        )
        totalSkippedDuplicates += recentImportResult.skippedDuplicateCount

        let shouldSuppressFlushWhilePaused = isUserPaused && pauseBehavior == .respectPause
        guard let sessionKey, !shouldSuppressFlushWhilePaused else {
            return Result(
                importedCount: totalImported,
                importedRecentTrackCount: recentImportResult.importedCount,
                flushedPlaybackHistoryCount: 0,
                flushedRecentTrackCount: 0,
                skippedDuplicateCount: totalSkippedDuplicates,
                recentTracksAuthorizationUnavailable: recentImportResult.isAuthorizationUnavailable,
                recentTracksStatus: recentImportResult.status
            )
        }

        var totalFlushedPlaybackHistoryCount = 0
        var totalFlushedRecentTrackCount = 0
        for _ in 0..<Limits.maxFlushBatches {
            if Task.isCancelled { break }

            let flushResult = await flushBacklog(
                backlog: backlog,
                scrobbleLog: scrobbleLog,
                sessionKey: sessionKey,
                recordSuccessfulScrobble: recordSuccessfulScrobble
            )
            let flushedPlaybackHistoryCount = flushResult.sentItems.reduce(into: 0) { count, item in
                if item.origin == .playbackHistory {
                    count += 1
                }
            }
            let flushedRecentTrackCount = flushResult.sentItems.reduce(into: 0) { count, item in
                if item.origin == .recentlyPlayed {
                    count += 1
                }
            }

            guard flushedPlaybackHistoryCount > 0 || flushedRecentTrackCount > 0 else { break }
            totalFlushedPlaybackHistoryCount += flushedPlaybackHistoryCount
            totalFlushedRecentTrackCount += flushedRecentTrackCount
        }

        return Result(
            importedCount: totalImported,
            importedRecentTrackCount: recentImportResult.importedCount,
            flushedPlaybackHistoryCount: totalFlushedPlaybackHistoryCount,
            flushedRecentTrackCount: totalFlushedRecentTrackCount,
            skippedDuplicateCount: totalSkippedDuplicates,
            recentTracksAuthorizationUnavailable: recentImportResult.isAuthorizationUnavailable,
            recentTracksStatus: recentImportResult.status
        )
    }

    private static func flushBacklog(
        backlog: ScrobbleBacklog,
        scrobbleLog: ScrobbleLogStore,
        sessionKey: String,
        recordSuccessfulScrobble: (() -> Void)?
    ) async -> ScrobbleBacklog.FlushResult {
        let pending = await backlog.pendingCount()
        guard pending > 0 else {
            return ScrobbleBacklog.FlushResult(sentCount: 0, skippedCount: 0, remainingCount: 0, sentItems: [])
        }

        AppGroup.userDefaults.set(Date(), forKey: Keys.lastBacklogFlushAt)

        let result = await backlog.flush(sessionKey: sessionKey)
        for item in result.sentItems {
            scrobbleLog.record(
                track: item.track,
                startTimestamp: item.startTimestamp,
                scrobbledAt: item.scrobbledAt,
                source: scrobbleLogSource(for: item.origin),
                lovedOnLastFM: item.lovedOnLastFM
            )
            recordSuccessfulScrobble?()
        }
        return result
    }

    private static func scrobbleLogSource(for origin: ScrobbleBacklog.Origin?) -> ScrobbleLogStore.Source {
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
