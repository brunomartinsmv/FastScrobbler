import Foundation

func runAppleMusicRecentTracksImporterTests() {
    section("Apple Music Recent Tracks · import state")

    struct RecentTrackFixture {
        let id: String
        let artist: String?
        let title: String?
        let album: String?
        let durationMillis: Int?
    }

    enum RecentImportStatus: String {
        case idle
        case disabled
        case authorizationUnavailable
        case cooldownDeferred
        case fetchFailed
        case seeded
        case noRecentTracks
        case noNewTracks
        case imported
        case skippedDuplicatesOnly
        case timestampConfidenceTooLow
    }

    struct TrackRecord: Equatable {
        var id: String
        var firstSeenAt: Int?
        var lastSeenAt: Int?
        var lastImportedSyntheticStart: Int?
        var lastImportedSyntheticEnd: Int?
        var lastImportedAt: Int?
        var lastSkippedReason: RecentImportStatus?
    }

    struct RecentImportState: Equatable {
        var hasSeeded = false
        var recentTracks: [TrackRecord] = []
        var lastFetchCount = 0
        var lastImportedCount = 0
        var lastSkippedDuplicateCount = 0
        var lastStatus: RecentImportStatus = .idle
        var nextEligibleAttemptAt: Int?
        var consecutiveFetchFailureCount = 0
        var consecutiveNoNewTrackCount = 0
        var consecutiveLowConfidenceCandidateCount = 0
    }

    struct RecentTrackCandidate: Equatable {
        let id: String
        let artist: String
        let title: String
        let album: String?
        let durationSeconds: Double
        let startTimestamp: Int
        let playedAtTimestamp: Int
        let withinLookbackWindow: Bool
    }

    func unseenPrefix(fetchedIDs: [String], knownIDs: [String], hasSeeded: Bool) -> [String] {
        guard hasSeeded else { return [] }
        let known = Set(knownIDs)
        return Array(fetchedIDs.prefix { !known.contains($0) })
    }

    func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func synthesizedCandidates(
        from tracks: [RecentTrackFixture],
        scanStartedAt: Int,
        fallbackDurationSeconds: Double = 180,
        maxLookbackSeconds: Int = 36 * 60 * 60
    ) -> [RecentTrackCandidate] {
        var estimatedEndAt = Double(scanStartedAt)
        var newestToOldest: [RecentTrackCandidate] = []

        for track in tracks {
            guard let artist = normalized(track.artist),
                  let title = normalized(track.title)
            else {
                continue
            }

            let usesFallbackDuration = (track.durationMillis ?? 0) <= 0

            let durationSeconds = usesFallbackDuration ? fallbackDurationSeconds : Double(track.durationMillis!) / 1000
            let startedAt = estimatedEndAt - durationSeconds
            let lookback = scanStartedAt - Int(floor(startedAt))

            newestToOldest.append(
                RecentTrackCandidate(
                    id: track.id,
                    artist: artist,
                    title: title,
                    album: normalized(track.album),
                    durationSeconds: durationSeconds,
                    startTimestamp: max(1, Int(floor(startedAt))),
                    playedAtTimestamp: Int(floor(estimatedEndAt)),
                    withinLookbackWindow: lookback <= maxLookbackSeconds
                )
            )
            estimatedEndAt = startedAt
        }

        return newestToOldest.reversed()
    }

    func pruneTrackRecords(_ records: [TrackRecord], limit: Int = 60) -> [TrackRecord] {
        var seen = Set<String>()
        return records
            .filter { !$0.id.isEmpty }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastSeenAt ?? lhs.firstSeenAt ?? Int.min
                let rhsDate = rhs.lastSeenAt ?? rhs.firstSeenAt ?? Int.min
                if lhsDate == rhsDate {
                    return lhs.id < rhs.id
                }
                return lhsDate > rhsDate
            }
            .compactMap { record in
                guard seen.insert(record.id).inserted else { return nil }
                return record
            }
            .prefix(limit)
            .map { $0 }
    }

    func migrateLegacyState(
        hasSeeded: Bool,
        recentTrackIDs: [String],
        lastFetchCount: Int,
        lastImportedCount: Int,
        lastSkippedDuplicateCount: Int,
        lastStatus: RecentImportStatus
    ) -> RecentImportState {
        RecentImportState(
            hasSeeded: hasSeeded,
            recentTracks: recentTrackIDs.map { TrackRecord(id: $0) },
            lastFetchCount: lastFetchCount,
            lastImportedCount: lastImportedCount,
            lastSkippedDuplicateCount: lastSkippedDuplicateCount,
            lastStatus: lastStatus
        )
    }

    func wasPreviouslyImported(
        candidateStart: Int,
        candidateEnd: Int,
        record: TrackRecord?,
        toleranceSeconds: Int = 90
    ) -> Bool {
        guard let record,
              let priorStart = record.lastImportedSyntheticStart,
              let priorEnd = record.lastImportedSyntheticEnd else {
            return false
        }
        return abs(priorStart - candidateStart) <= toleranceSeconds &&
            abs(priorEnd - candidateEnd) <= toleranceSeconds
    }

    func statusAfterImport(
        resourcesCount: Int,
        importedCount: Int,
        skippedDuplicateCount: Int,
        skippedLowConfidenceCount: Int,
        hadCandidates: Bool
    ) -> RecentImportStatus {
        if resourcesCount == 0 { return .noRecentTracks }
        if importedCount > 0 { return .imported }
        if skippedLowConfidenceCount > 0 && skippedDuplicateCount == 0 { return .timestampConfidenceTooLow }
        if skippedDuplicateCount > 0 && hadCandidates { return .skippedDuplicatesOnly }
        return .noNewTracks
    }

    func applyCooldownAfterNoOp(_ state: inout RecentImportState, now: Int, cooldownSeconds: Int = 60) {
        state.consecutiveNoNewTrackCount += 1
        state.nextEligibleAttemptAt = now + cooldownSeconds
    }

    func applyCooldownAfterFailure(_ state: inout RecentImportState, now: Int, cooldownSeconds: Int = 60) {
        state.consecutiveFetchFailureCount += 1
        state.consecutiveNoNewTrackCount = 0
        state.nextEligibleAttemptAt = now + cooldownSeconds
        state.lastStatus = .fetchFailed
    }

    func clearCooldownAfterImport(_ state: inout RecentImportState) {
        state.nextEligibleAttemptAt = nil
        state.consecutiveFetchFailureCount = 0
        state.consecutiveNoNewTrackCount = 0
    }

    func shouldDeferForCooldown(now: Int, nextEligibleAttemptAt: Int?, bypassCooldown: Bool = false) -> Bool {
        guard !bypassCooldown else { return false }
        guard let nextEligibleAttemptAt else { return false }
        return now < nextEligibleAttemptAt
    }

    expect(
        "first successful scan seeds state without importing old recent tracks",
        unseenPrefix(fetchedIDs: ["a", "b", "c"], knownIDs: [], hasSeeded: false).isEmpty
    )

    expectEqual(
        "subsequent scan imports only unseen tracks before the first known recent ID",
        unseenPrefix(fetchedIDs: ["newest", "newer", "known", "old"], knownIDs: ["known", "older"], hasSeeded: true),
        ["newest", "newer"]
    )

    let migrated = migrateLegacyState(
        hasSeeded: true,
        recentTrackIDs: ["legacy-a", "legacy-b"],
        lastFetchCount: 2,
        lastImportedCount: 0,
        lastSkippedDuplicateCount: 0,
        lastStatus: .seeded
    )
    expect("legacy migration preserves seeded state", migrated.hasSeeded)
    expectEqual("legacy migration stores track records for prior IDs", migrated.recentTracks.map(\.id), ["legacy-a", "legacy-b"])
    expectEqual("legacy migration does not fabricate imported timestamps", migrated.recentTracks.first?.lastImportedSyntheticStart, nil)

    let pruned = pruneTrackRecords([
        TrackRecord(id: "older", firstSeenAt: 10, lastSeenAt: 20),
        TrackRecord(id: "newer", firstSeenAt: 30, lastSeenAt: 40),
        TrackRecord(id: "older", firstSeenAt: 5, lastSeenAt: 6),
    ])
    expectEqual("track record pruning keeps most recently seen unique IDs first", pruned.map(\.id), ["newer", "older"])

    section("Apple Music Recent Tracks · timestamp synthesis")

    let synthesized = synthesizedCandidates(
        from: [
            RecentTrackFixture(id: "newest", artist: "Artist C", title: "Song C", album: "Album C", durationMillis: 30_000),
            RecentTrackFixture(id: "middle", artist: "Artist B", title: "Song B", album: nil, durationMillis: 60_000),
            RecentTrackFixture(id: "oldest", artist: "Artist A", title: "Song A", album: "Album A", durationMillis: 90_000),
        ],
        scanStartedAt: 1_000
    )

    expectEqual("synthesized candidates are queued oldest-to-newest", synthesized.map(\.id), ["oldest", "middle", "newest"])
    expectEqual("oldest start timestamp subtracts all newer durations", synthesized.first?.startTimestamp, 820)
    expectEqual("newest track ends at scan time", synthesized.last?.playedAtTimestamp, 1_000)

    let fallbackLimited = synthesizedCandidates(
        from: [
            RecentTrackFixture(id: "newest", artist: "Artist C", title: "Song C", album: nil, durationMillis: nil),
            RecentTrackFixture(id: "middle", artist: "Artist B", title: "Song B", album: nil, durationMillis: 60_000),
            RecentTrackFixture(id: "oldest", artist: "Artist A", title: "Song A", album: nil, durationMillis: nil),
        ],
        scanStartedAt: 1_000
    )
    expectEqual("fallback-duration candidates are still synthesized oldest-to-newest", fallbackLimited.map(\.id), ["oldest", "middle", "newest"])
    expect("fallback-duration candidates remain eligible when within lookback", fallbackLimited.allSatisfy(\.withinLookbackWindow))

    let farLookback = synthesizedCandidates(
        from: [
            RecentTrackFixture(id: "newest", artist: "Artist 1", title: "Song 1", album: nil, durationMillis: 43_201_000),
            RecentTrackFixture(id: "middle", artist: "Artist 2", title: "Song 2", album: nil, durationMillis: 43_201_000),
            RecentTrackFixture(id: "oldest", artist: "Artist 3", title: "Song 3", album: nil, durationMillis: 43_201_000),
        ],
        scanStartedAt: 200_000
    )
    expect("candidates beyond 36 hours synthesized lookback are rejected", !farLookback.first!.withinLookbackWindow)
    expect("newer candidates inside 36 hours remain eligible", farLookback.last!.withinLookbackWindow)

    let filtered = synthesizedCandidates(
        from: [
            RecentTrackFixture(id: "blankArtist", artist: " ", title: "Song", album: nil, durationMillis: 10_000),
            RecentTrackFixture(id: "blankTitle", artist: "Artist", title: nil, album: nil, durationMillis: 10_000),
            RecentTrackFixture(id: "missingDuration", artist: "Artist", title: "Song", album: nil, durationMillis: nil),
            RecentTrackFixture(id: "valid", artist: " Artist ", title: " Song ", album: " Album ", durationMillis: 10_000),
        ],
        scanStartedAt: 500
    )
    expectEqual("only metadata-invalid recent tracks are skipped", filtered.map(\.id), ["valid", "missingDuration"])
    expectEqual("missing duration falls back to three minutes", Int(filtered[1].durationSeconds), 180)
    expectEqual("valid recent track metadata is trimmed", [filtered[0].artist, filtered[0].title, filtered[0].album ?? ""], ["Artist", "Song", "Album"])

    section("Apple Music Recent Tracks · duplicate and result accounting")

    let priorImport = TrackRecord(
        id: "song-a",
        firstSeenAt: 100,
        lastSeenAt: 200,
        lastImportedSyntheticStart: 10_000,
        lastImportedSyntheticEnd: 10_180,
        lastImportedAt: 200,
        lastSkippedReason: nil
    )
    expect("same ID within prior synthetic start/end tolerance is skipped",
           wasPreviouslyImported(candidateStart: 10_060, candidateEnd: 10_220, record: priorImport))
    expect("same ID outside prior synthetic tolerance is not considered exact prior import reuse",
           !wasPreviouslyImported(candidateStart: 10_091, candidateEnd: 10_271, record: priorImport))

    expectEqual(
        "lookback-rejected pass reports timestampConfidenceTooLow",
        statusAfterImport(resourcesCount: 2, importedCount: 0, skippedDuplicateCount: 0, skippedLowConfidenceCount: 2, hadCandidates: true),
        .timestampConfidenceTooLow
    )
    expectEqual(
        "duplicate-only pass is reported",
        statusAfterImport(resourcesCount: 5, importedCount: 0, skippedDuplicateCount: 3, skippedLowConfidenceCount: 0, hadCandidates: true),
        .skippedDuplicatesOnly
    )
    expectEqual(
        "successful import status is reported",
        statusAfterImport(resourcesCount: 5, importedCount: 2, skippedDuplicateCount: 1, skippedLowConfidenceCount: 1, hadCandidates: true),
        .imported
    )

    section("Apple Music Recent Tracks · cooldowns and diagnostics")

    var failureState = RecentImportState()
    applyCooldownAfterFailure(&failureState, now: 1_000)
    expectEqual("fetch failure sets 1-minute cooldown", failureState.nextEligibleAttemptAt, 1_060)
    expectEqual("fetch failure increments failure count", failureState.consecutiveFetchFailureCount, 1)
    expectEqual("fetch failure status remains fetchFailed", failureState.lastStatus, .fetchFailed)

    var noOpState = RecentImportState()
    applyCooldownAfterNoOp(&noOpState, now: 2_000)
    expectEqual("no-op success sets 1-minute cooldown", noOpState.nextEligibleAttemptAt, 2_060)
    expectEqual("no-op success increments no-new counter", noOpState.consecutiveNoNewTrackCount, 1)

    expect("cooldown gate defers attempts before next eligible time",
           shouldDeferForCooldown(now: 2_050, nextEligibleAttemptAt: noOpState.nextEligibleAttemptAt))
    expect("cooldown gate allows attempts at or after next eligible time",
           !shouldDeferForCooldown(now: 2_060, nextEligibleAttemptAt: noOpState.nextEligibleAttemptAt))
    expect("manual scans can bypass the recent-track cooldown gate",
           !shouldDeferForCooldown(now: 2_050, nextEligibleAttemptAt: noOpState.nextEligibleAttemptAt, bypassCooldown: true))

    noOpState.consecutiveFetchFailureCount = 2
    clearCooldownAfterImport(&noOpState)
    expectEqual("successful import clears cooldown", noOpState.nextEligibleAttemptAt, nil)
    expectEqual("successful import resets no-new counter", noOpState.consecutiveNoNewTrackCount, 0)
    expectEqual("successful import resets failure counter", noOpState.consecutiveFetchFailureCount, 0)

    var diagnosticState = RecentImportState()
    diagnosticState.consecutiveLowConfidenceCandidateCount = 3
    expectEqual("diagnostics track consecutive low-confidence candidate count", diagnosticState.consecutiveLowConfidenceCandidateCount, 3)

    section("Apple Music Recent Tracks · favorite parity")

    func shouldMarkFavorite(playbackStoreID: String?, favoriteStoreIDs: Set<String>) -> Bool {
        guard let playbackStoreID, !playbackStoreID.isEmpty else { return false }
        return favoriteStoreIDs.contains(playbackStoreID)
    }

    func libraryIndexContains(playbackStoreID: String?, libraryStoreIDs: Set<String>) -> Bool {
        guard let playbackStoreID else { return false }
        let trimmed = playbackStoreID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return libraryStoreIDs.contains(trimmed)
    }

    func shouldImportRecentTrack(
        toggleEnabled: Bool,
        playbackStoreID: String?,
        libraryStoreIDs: Set<String>?
    ) -> Bool {
        guard toggleEnabled else { return true }
        guard let libraryStoreIDs else { return true }
        return !libraryIndexContains(playbackStoreID: playbackStoreID, libraryStoreIDs: libraryStoreIDs)
    }

    expect("favorite parity uses playback store ID matches", shouldMarkFavorite(playbackStoreID: "track-123", favoriteStoreIDs: ["track-123"]))
    expect("favorite parity ignores missing playback store IDs", !shouldMarkFavorite(playbackStoreID: nil, favoriteStoreIDs: ["track-123"]))
    expect("favorite parity does not mark unrelated tracks", !shouldMarkFavorite(playbackStoreID: "track-999", favoriteStoreIDs: ["track-123"]))

    section("Apple Music Recent Tracks · non-library filter")

    expect("non-library filter disabled preserves current import behavior",
           shouldImportRecentTrack(toggleEnabled: false, playbackStoreID: "track-123", libraryStoreIDs: ["track-123"]))
    expect("non-library filter skips tracks confirmed to be in the local library",
           !shouldImportRecentTrack(toggleEnabled: true, playbackStoreID: "track-123", libraryStoreIDs: ["track-123"]))
    expect("non-library filter still imports tracks outside the local library",
           shouldImportRecentTrack(toggleEnabled: true, playbackStoreID: "track-999", libraryStoreIDs: ["track-123"]))
    expect("non-library filter still imports tracks when library membership cannot be resolved",
           shouldImportRecentTrack(toggleEnabled: true, playbackStoreID: "track-123", libraryStoreIDs: nil))
    expect("non-library filter does not falsely match empty playback store IDs",
           shouldImportRecentTrack(toggleEnabled: true, playbackStoreID: " ", libraryStoreIDs: ["track-123"]))

    let manualResult = ListeningHistoryScanServiceResult(
        importedCount: 2,
        importedRecentTrackCount: 3,
        flushedPlaybackHistoryCount: 1,
        flushedRecentTrackCount: 2,
        skippedDuplicateCount: 4
    )
    expectEqual("manual scan result totals include library and recent imports", manualResult.totalImportedCount, 5)
    expectEqual("manual scan result totals include library and recent flushes", manualResult.totalFlushedCount, 3)
    expectEqual("manual scan result keeps duplicate skip count", manualResult.skippedDuplicateCount, 4)
}

private struct ListeningHistoryScanServiceResult {
    let importedCount: Int
    let importedRecentTrackCount: Int
    let flushedPlaybackHistoryCount: Int
    let flushedRecentTrackCount: Int
    let skippedDuplicateCount: Int

    var totalImportedCount: Int { importedCount + importedRecentTrackCount }
    var totalFlushedCount: Int { flushedPlaybackHistoryCount + flushedRecentTrackCount }
}
