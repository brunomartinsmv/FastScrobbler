import Foundation

func runListeningHistoryScanTests() {
    enum SimFlushOrigin {
        case live
        case playbackHistory
        case recentlyPlayed
        case manual
    }

    enum RecentTracksStatus {
        case authorizationUnavailable
        case seeded
        case fetchFailed
        case other
    }

    // ─── Listening History scan orchestration ────────────────────────────────────

    section("Listening History scan · One-press orchestration")

    func simulateListeningHistoryScan(
        importBatches: [Int],
        skippedDuplicateBatches: [Int] = [],
        flushBatches: [[SimFlushOrigin]],
        importBatchSize: Int = 200,
        maxImports: Int = 2000,
        maxFlushBatches: Int = 80
    ) -> (imported: Int, skippedDuplicates: Int, flushedPlaybackHistory: Int, importCalls: Int, flushCalls: Int) {
        var totalImported = 0
        var totalSkippedDuplicates = 0
        var importCalls = 0
        var importIndex = 0

        if importBatchSize > 0 {
            while totalImported < maxImports {
                let batchLimit = min(importBatchSize, maxImports - totalImported)
                guard batchLimit > 0 else { break }

                let requestedBatch = importIndex < importBatches.count ? importBatches[importIndex] : 0
                let skippedDuplicates = importIndex < skippedDuplicateBatches.count ? skippedDuplicateBatches[importIndex] : 0
                importIndex += 1
                importCalls += 1

                let imported = min(requestedBatch, batchLimit)
                totalSkippedDuplicates += skippedDuplicates
                guard imported > 0 else { break }
                totalImported += imported
            }
        }

        var totalFlushedPlaybackHistory = 0
        var flushCalls = 0
        var flushIndex = 0

        while flushCalls < maxFlushBatches {
            let origins = flushIndex < flushBatches.count ? flushBatches[flushIndex] : []
            flushIndex += 1
            flushCalls += 1

            let flushedPlaybackHistory = origins.filter { $0 == .playbackHistory }.count
            guard flushedPlaybackHistory > 0 else { break }
            totalFlushedPlaybackHistory += flushedPlaybackHistory
        }

        return (totalImported, totalSkippedDuplicates, totalFlushedPlaybackHistory, importCalls, flushCalls)
    }

    let multiBatchScan = simulateListeningHistoryScan(
        importBatches: [200, 200, 75, 0],
        flushBatches: [
            Array(repeating: .playbackHistory, count: 25),
            Array(repeating: .playbackHistory, count: 25),
            []
        ]
    )
    expectEqual("imports accumulate across batches until zero", multiBatchScan.imported, 475)
    expectEqual("no duplicate skips defaults to zero", multiBatchScan.skippedDuplicates, 0)
    expectEqual("import loop includes final zero batch call", multiBatchScan.importCalls, 4)
    expectEqual("flushes accumulate playback-history batches until zero", multiBatchScan.flushedPlaybackHistory, 50)
    expectEqual("flush loop includes final zero batch call", multiBatchScan.flushCalls, 3)

    let cappedImportScan = simulateListeningHistoryScan(
        importBatches: Array(repeating: 200, count: 20),
        flushBatches: []
    )
    expectEqual("import loop stops at max import cap", cappedImportScan.imported, 2000)
    expectEqual("import cap avoids one extra zero-probe call", cappedImportScan.importCalls, 10)

    let cappedFlushScan = simulateListeningHistoryScan(
        importBatches: [0],
        flushBatches: Array(repeating: Array(repeating: .playbackHistory, count: 25), count: 100)
    )
    expectEqual("flush loop stops at max flush batch cap", cappedFlushScan.flushedPlaybackHistory, 2000)
    expectEqual("flush cap stops after configured batch count", cappedFlushScan.flushCalls, 80)

    let blockedFlushScan = simulateListeningHistoryScan(
        importBatches: [50, 0],
        flushBatches: [
            [.live, .manual],
            Array(repeating: .playbackHistory, count: 25)
        ]
    )
    expectEqual("flush loop stops when a batch sends no playback-history items", blockedFlushScan.flushedPlaybackHistory, 0)
    expectEqual("blocked flush stops without probing later batches", blockedFlushScan.flushCalls, 1)

    let duplicateScan = simulateListeningHistoryScan(
        importBatches: [10, 0],
        skippedDuplicateBatches: [2, 7],
        flushBatches: []
    )
    expectEqual("scan accumulates duplicate skips from import batches", duplicateScan.skippedDuplicates, 9)

    section("Listening History scan · foreground startup ordering")

    enum ForegroundAction: String, Equatable {
        case startEngine
        case tickEngine
        case scanListeningHistory
        case flushBacklog
        case scheduleBackgroundProcessing
    }

    func foregroundStartupActions(isUserPaused: Bool) -> [ForegroundAction] {
        var actions: [ForegroundAction] = []

        if !isUserPaused {
            actions.append(.startEngine)
            actions.append(.tickEngine)
            actions.append(.scanListeningHistory)
            actions.append(.flushBacklog)
        }

        actions.append(.scheduleBackgroundProcessing)

        if !isUserPaused {
            actions.append(.startEngine)
            actions.append(.tickEngine)
        }

        return actions
    }

    func firstIndex(of action: ForegroundAction, in actions: [ForegroundAction]) -> Int? {
        actions.firstIndex(of: action)
    }

    let standardForegroundStart = foregroundStartupActions(isUserPaused: false)
    expect(
        "foreground startup primes the live session before scanning listening history",
        (firstIndex(of: .tickEngine, in: standardForegroundStart) ?? .max) <
            (firstIndex(of: .scanListeningHistory, in: standardForegroundStart) ?? .max)
    )
    expect(
        "foreground startup scans listening history before flushing backlog",
        (firstIndex(of: .scanListeningHistory, in: standardForegroundStart) ?? .max) <
            (firstIndex(of: .flushBacklog, in: standardForegroundStart) ?? .max)
    )
    expect(
        "foreground startup uses the unified scan path",
        standardForegroundStart.contains(.scanListeningHistory)
    )

    let pausedForegroundStart = foregroundStartupActions(isUserPaused: true)
    expect(
        "paused startup does not scan listening history",
        !pausedForegroundStart.contains(.scanListeningHistory)
    )
    expect(
        "paused startup does not submit backlog",
        !pausedForegroundStart.contains(.flushBacklog)
    )

    section("Listening History scan · user-triggered orchestration")

    enum UserInitiatedEntryPoint: CaseIterable {
        case homeRefresh
        case settingsScan
        case shortcutScan
    }

    enum UserInitiatedAction: String, Equatable {
        case refreshObserver
        case startEngine
        case tickEngine
        case runSharedScan
    }

    func userInitiatedScanActions(entryPoint: UserInitiatedEntryPoint, isUserPaused: Bool) -> [UserInitiatedAction] {
        var actions: [UserInitiatedAction] = []

        if !isUserPaused, entryPoint != .shortcutScan {
            actions.append(.refreshObserver)
            actions.append(.startEngine)
            actions.append(.tickEngine)
        }

        actions.append(.runSharedScan)
        return actions
    }

    for entryPoint in UserInitiatedEntryPoint.allCases {
        let actions = userInitiatedScanActions(entryPoint: entryPoint, isUserPaused: false)
        let expected: [UserInitiatedAction] = entryPoint == .shortcutScan
            ? [.runSharedScan]
            : [.refreshObserver, .startEngine, .tickEngine, .runSharedScan]
        expectEqual("user-triggered scan path is correct for \(entryPoint)", actions, expected)
    }

    for entryPoint in UserInitiatedEntryPoint.allCases {
        let actions = userInitiatedScanActions(entryPoint: entryPoint, isUserPaused: true)
        expectEqual(
            "paused user-triggered scans skip live priming for \(entryPoint)",
            actions,
            [.runSharedScan]
        )
    }

    section("Listening History scan · empty-result retry")

    func simulateRetryablePlaybackHistoryScan(
        firstPassImported: Int,
        firstPassSkippedDuplicates: Int,
        retryImported: Int,
        retrySkippedDuplicates: Int = 0,
        isUserPaused: Bool,
        retryEnabled: Bool
    ) -> (totalImported: Int, totalSkippedDuplicates: Int, retryRan: Bool, importPasses: Int) {
        var totalImported = firstPassImported
        var totalSkippedDuplicates = firstPassSkippedDuplicates
        var retryRan = false
        var importPasses = 1

        let shouldRetry =
            retryEnabled &&
            !isUserPaused &&
            firstPassImported == 0 &&
            firstPassSkippedDuplicates == 0

        if shouldRetry {
            retryRan = true
            importPasses += 1
            totalImported += retryImported
            totalSkippedDuplicates += retrySkippedDuplicates
        }

        return (totalImported, totalSkippedDuplicates, retryRan, importPasses)
    }

    let delayedMetadataRecovery = simulateRetryablePlaybackHistoryScan(
        firstPassImported: 0,
        firstPassSkippedDuplicates: 0,
        retryImported: 3,
        isUserPaused: false,
        retryEnabled: true
    )
    expect("empty first pass triggers exactly one retry", delayedMetadataRecovery.retryRan)
    expectEqual("retry imports late library plays", delayedMetadataRecovery.totalImported, 3)
    expectEqual("retry performs exactly two playback-history import passes", delayedMetadataRecovery.importPasses, 2)

    let noRetryAfterSuccess = simulateRetryablePlaybackHistoryScan(
        firstPassImported: 2,
        firstPassSkippedDuplicates: 0,
        retryImported: 5,
        isUserPaused: false,
        retryEnabled: true
    )
    expect("successful first pass skips retry", !noRetryAfterSuccess.retryRan)
    expectEqual("successful first pass keeps original import count", noRetryAfterSuccess.totalImported, 2)

    let noRetryAfterDuplicates = simulateRetryablePlaybackHistoryScan(
        firstPassImported: 0,
        firstPassSkippedDuplicates: 2,
        retryImported: 4,
        isUserPaused: false,
        retryEnabled: true
    )
    expect("duplicate-only first pass skips retry", !noRetryAfterDuplicates.retryRan)
    expectEqual("duplicate-only first pass preserves skipped duplicate count", noRetryAfterDuplicates.totalSkippedDuplicates, 2)

    let noRetryWhilePaused = simulateRetryablePlaybackHistoryScan(
        firstPassImported: 0,
        firstPassSkippedDuplicates: 0,
        retryImported: 4,
        isUserPaused: true,
        retryEnabled: true
    )
    expect("paused scans do not retry empty playback-history results", !noRetryWhilePaused.retryRan)

    // ─── Listening History scan cutoff ───────────────────────────────────────────

    section("Listening History scan · First-scan lookback")

    enum PlaybackHistoryImportMode {
        case newPlaysOnly
        case recentBackfill
    }

    func playbackHistoryFetchCutoff(
        now: Int,
        lastImportAt: Int?,
        mode: PlaybackHistoryImportMode,
        extendedLookback: Bool = false,
        maxStandardLookbackHours: Int = 36,
        maxRecentBackfillLookbackDays: Int = 7
    ) -> Int {
        let standardLookback = now - maxStandardLookbackHours * 60 * 60
        let recentBackfillLookback = now - maxRecentBackfillLookbackDays * 24 * 60 * 60
        let lookback: Int = {
            switch mode {
            case .newPlaysOnly:
                return standardLookback
            case .recentBackfill:
                return extendedLookback ? recentBackfillLookback : standardLookback
            }
        }()
        let cutoff = lastImportAt ?? lookback

        if mode == .recentBackfill { return lookback }
        guard lastImportAt != nil else { return max(cutoff, lookback) }
        return lookback
    }

    let now = 1_000_000
    expectEqual(
        "automatic import uses 36-hour lookback cap",
        playbackHistoryFetchCutoff(now: now, lastImportAt: now - 2 * 60 * 60, mode: .newPlaysOnly),
        now - 36 * 60 * 60
    )
    expectEqual(
        "manual standard scan uses 36-hour lookback",
        playbackHistoryFetchCutoff(now: now, lastImportAt: nil, mode: .recentBackfill),
        now - 36 * 60 * 60
    )
    expectEqual(
        "manual extended scan uses 7-day lookback",
        playbackHistoryFetchCutoff(now: now, lastImportAt: nil, mode: .recentBackfill, extendedLookback: true),
        now - 7 * 24 * 60 * 60
    )
    expectEqual(
        "manual standard scan keeps 36-hour lookback even with an existing cursor",
        playbackHistoryFetchCutoff(now: now, lastImportAt: now - 2 * 60 * 60, mode: .recentBackfill),
        now - 36 * 60 * 60
    )
    expectEqual(
        "manual extended scan keeps 7-day lookback even with an existing cursor",
        playbackHistoryFetchCutoff(now: now, lastImportAt: now - 2 * 60 * 60, mode: .recentBackfill, extendedLookback: true),
        now - 7 * 24 * 60 * 60
    )

    func shouldInitializeCursorWithoutImport(lastImportAt: Int?, mode: PlaybackHistoryImportMode) -> Bool {
        lastImportAt == nil && mode == .newPlaysOnly
    }

    expect(
        "automatic first import initializes cursor instead of backfilling",
        shouldInitializeCursorWithoutImport(lastImportAt: nil, mode: .newPlaysOnly)
    )
    expect(
        "manual first scan remains an explicit recent-history backfill",
        !shouldInitializeCursorWithoutImport(lastImportAt: nil, mode: .recentBackfill)
    )

    // ─── Listening History scan dialog summary ───────────────────────────────────

    section("Listening History scan · Dialog summary")

    func listeningHistorySummary(importedCount: Int, skippedDuplicateCount: Int, flushedOrigins: [SimFlushOrigin]) -> String? {
        let flushedPlaybackHistoryCount = flushedOrigins.filter { $0 == .playbackHistory }.count
        guard importedCount > 0 || flushedPlaybackHistoryCount > 0 || skippedDuplicateCount > 0 else {
            return nil
        }
        return "Found \(importedCount); Submitted \(flushedPlaybackHistoryCount); Skipped \(skippedDuplicateCount)"
    }

    func listeningHistoryEmptyStateMessage(recentTracksStatus: RecentTracksStatus) -> String {
        switch recentTracksStatus {
        case .authorizationUnavailable:
            return "No new library plays found. Apple Music recent tracks could not be checked because Music access is disabled."
        case .seeded:
            return "Apple Music recent tracks were initialized from your current history. Future scans will only import newer plays."
        case .fetchFailed:
            return "No new library plays found. Apple Music recent tracks could not be checked because the Apple Music API request failed."
        case .other:
            return "No new plays found. Scrobbling from Listening History only works for songs added to your Library."
        }
    }

    func pausedScanResult(importedCount: Int, importedRecentTrackCount: Int, skippedDuplicateCount: Int) -> (flushedPlaybackHistory: Int, flushedRecentTracks: Int, skippedDuplicates: Int) {
        (flushedPlaybackHistory: 0, flushedRecentTracks: 0, skippedDuplicates: skippedDuplicateCount)
    }

    func pausedExplicitScanResult(
        importedCount: Int,
        importedRecentTrackCount: Int,
        skippedDuplicateCount: Int
    ) -> (flushedPlaybackHistory: Int, flushedRecentTracks: Int, skippedDuplicates: Int) {
        (
            flushedPlaybackHistory: importedCount,
            flushedRecentTracks: importedRecentTrackCount,
            skippedDuplicates: skippedDuplicateCount
        )
    }

    expectEqual(
        "summary reports flushed playback-history plays separately",
        listeningHistorySummary(importedCount: 0, skippedDuplicateCount: 0, flushedOrigins: [.playbackHistory, .playbackHistory]),
        "Found 0; Submitted 2; Skipped 0"
    )
    expectEqual(
        "summary reports imports when no playback-history items were flushed",
        listeningHistorySummary(importedCount: 3, skippedDuplicateCount: 0, flushedOrigins: []),
        "Found 3; Submitted 0; Skipped 0"
    )
    expectEqual(
        "summary ignores non-playback-history flushes",
        listeningHistorySummary(importedCount: 0, skippedDuplicateCount: 0, flushedOrigins: [.live, .manual, .recentlyPlayed]),
        nil
    )
    expectEqual(
        "summary includes duplicate skips",
        listeningHistorySummary(importedCount: 0, skippedDuplicateCount: 5, flushedOrigins: []),
        "Found 0; Submitted 0; Skipped 5"
    )
    expectEqual(
        "mixed flush origins count only playback-history submissions",
        listeningHistorySummary(importedCount: 4, skippedDuplicateCount: 1, flushedOrigins: [.live, .playbackHistory, .manual, .playbackHistory]),
        "Found 4; Submitted 2; Skipped 1"
    )
    let pausedResult = pausedScanResult(importedCount: 3, importedRecentTrackCount: 2, skippedDuplicateCount: 1)
    expectEqual("paused scan suppresses playback-history flushes", pausedResult.flushedPlaybackHistory, 0)
    expectEqual("paused scan suppresses recent-track flushes", pausedResult.flushedRecentTracks, 0)
    expectEqual("paused scan still reports duplicate skips", pausedResult.skippedDuplicates, 1)
    let pausedExplicitResult = pausedExplicitScanResult(importedCount: 3, importedRecentTrackCount: 2, skippedDuplicateCount: 1)
    expectEqual("paused explicit scan flushes playback-history items", pausedExplicitResult.flushedPlaybackHistory, 3)
    expectEqual("paused explicit scan flushes recent-track items", pausedExplicitResult.flushedRecentTracks, 2)
    expectEqual("paused explicit scan still reports duplicate skips", pausedExplicitResult.skippedDuplicates, 1)
    expectEqual(
        "empty-state auth message remains specific",
        listeningHistoryEmptyStateMessage(recentTracksStatus: .authorizationUnavailable),
        "No new library plays found. Apple Music recent tracks could not be checked because Music access is disabled."
    )
    expectEqual(
        "empty-state seeded message explains first-run behavior",
        listeningHistoryEmptyStateMessage(recentTracksStatus: .seeded),
        "Apple Music recent tracks were initialized from your current history. Future scans will only import newer plays."
    )
    expectEqual(
        "empty-state fetch-failed message is distinct",
        listeningHistoryEmptyStateMessage(recentTracksStatus: .fetchFailed),
        "No new library plays found. Apple Music recent tracks could not be checked because the Apple Music API request failed."
    )
}
