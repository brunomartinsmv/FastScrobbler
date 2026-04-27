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
        flushBatches: [[SimFlushOrigin]],
        importBatchSize: Int = 200,
        maxImports: Int = 2000,
        maxFlushBatches: Int = 80
    ) -> (imported: Int, flushedPlaybackHistory: Int, importCalls: Int, flushCalls: Int) {
        var totalImported = 0
        var importCalls = 0
        var importIndex = 0

        if importBatchSize > 0 {
            while totalImported < maxImports {
                let batchLimit = min(importBatchSize, maxImports - totalImported)
                guard batchLimit > 0 else { break }

                let requestedBatch = importIndex < importBatches.count ? importBatches[importIndex] : 0
                importIndex += 1
                importCalls += 1

                let imported = min(requestedBatch, batchLimit)
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

        return (totalImported, totalFlushedPlaybackHistory, importCalls, flushCalls)
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

    // ─── Listening History scan dialog counting ──────────────────────────────────

    section("Listening History scan · Dialog counting")

    func listeningHistoryDialogCount(importedCount: Int, flushedOrigins: [SimFlushOrigin]) -> Int {
        let flushedPlaybackHistoryCount = flushedOrigins.filter { $0 == .playbackHistory }.count
        if flushedPlaybackHistoryCount > 0 {
            return flushedPlaybackHistoryCount
        }
        return importedCount
    }

    expectEqual(
        "flushed playback-history plays override a zero importer count",
        listeningHistoryDialogCount(importedCount: 0, flushedOrigins: [.playbackHistory, .playbackHistory]),
        2
    )
    expectEqual(
        "imported count is used when no playback-history items were flushed",
        listeningHistoryDialogCount(importedCount: 3, flushedOrigins: []),
        3
    )
    expectEqual(
        "non-playback-history flushes do not affect the dialog count",
        listeningHistoryDialogCount(importedCount: 0, flushedOrigins: [.live, .manual, .recentlyPlayed]),
        0
    )
    expectEqual(
        "mixed flush origins count only playback-history items",
        listeningHistoryDialogCount(importedCount: 4, flushedOrigins: [.live, .playbackHistory, .manual, .playbackHistory]),
        2
    )
}
