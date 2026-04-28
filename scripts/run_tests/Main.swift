@main
struct RunTestsMain {
    static func main() {
        runBracketRemovalTests()
        runHTTPTimeoutTests()
        runManualCooldownTests()
        runBacklogFlushContinuationTests()
        runProMetadataTests()
        runScrobbleEngineTests()
        runNowPlayingRateLimitTests()
        runDedupTimestampToleranceTests()
        runListeningHistoryRecoveryTests()
        runDedupNearestMatchTests()
        runBacklogTests()
        runAdditionalBracketEdgeCaseTests()
        runAPITests()
        runManualScrobbleTests()
        runTextReplacementTests()
        runBackgroundGracePeriodTests()
        runSettingsDefaultsTests()
        runBacklogTimestampPreservationTests()
        runBacklogCleanupTests()
        runListeningHistoryScanTests()
        finishTests()
    }
}
