import Foundation

func runListeningHistoryScanTests() {
    enum SimFlushOrigin {
        case live
        case playbackHistory
        case recentlyPlayed
        case manual
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

    // ─── Listening History scan cutoff ───────────────────────────────────────────

    section("Listening History scan · First-scan lookback")

    func playbackHistoryFetchCutoff(
        now: Int,
        lastImportAt: Int?,
        maxLookbackDays: Int = 7,
        sameDeviceRecoveryHours: Int = 24,
        allDevices: Bool
    ) -> Int {
        let lookback = now - maxLookbackDays * 24 * 60 * 60
        let cutoff = lastImportAt ?? lookback

        guard lastImportAt != nil else { return max(cutoff, lookback) }
        if allDevices { return lookback }

        let recoveryStart = cutoff - sameDeviceRecoveryHours * 60 * 60
        return max(recoveryStart, lookback)
    }

    let now = 1_000_000
    expectEqual(
        "first scan uses 7-day lookback",
        playbackHistoryFetchCutoff(now: now, lastImportAt: nil, allDevices: false),
        now - 7 * 24 * 60 * 60
    )
    expectEqual(
        "later same-device scan looks back 24 hours from cursor",
        playbackHistoryFetchCutoff(now: now, lastImportAt: now - 2 * 60 * 60, allDevices: false),
        now - 26 * 60 * 60
    )
    expectEqual(
        "all-devices scan uses bounded 7-day lookback",
        playbackHistoryFetchCutoff(now: now, lastImportAt: now - 2 * 60 * 60, allDevices: true),
        now - 7 * 24 * 60 * 60
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
}
