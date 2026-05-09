import Foundation

func runListeningHistoryRecoveryTests() {
    // ─── Listening History repeated-play recovery ────────────────────────────────
    // Replicates the count-based recovery logic in PlaybackHistoryImporter.

    section("Listening History · Repeated play recovery")

    func recoveredPlaybackHistoryStartTimestamps(
        playCount: Int,
        previousPlayCount: Int?,
        playedAt: Int,
        durationSeconds: Int?,
        previousSeenPlayedAt: Int?,
        preventDuplicates: Bool,
        scrobbleLoopedTracks: Bool
    ) -> [Int] {
        let delta: Int = {
            guard let previousPlayCount else {
                return 1
            }
            let d = playCount - previousPlayCount
            if d > 0 { return d }
            return 1
        }()

        let playsToImport: Int = {
            return max(delta, 1)
        }()

        let synthesizedPlayCount = playsToImport

        if let durationSeconds, durationSeconds > 0 {
            return (0..<synthesizedPlayCount).map { index in
                playedAt - durationSeconds * (synthesizedPlayCount - index)
            }
        }

        guard synthesizedPlayCount > 1 else { return [playedAt] }

        return (0..<synthesizedPlayCount).map { index in
            playedAt - (synthesizedPlayCount - index - 1)
        }
    }

    let recoveredStarts = recoveredPlaybackHistoryStartTimestamps(
        playCount: 20,
        previousPlayCount: nil,
        playedAt: 1_234,
        durationSeconds: 12,
        previousSeenPlayedAt: nil,
        preventDuplicates: false,
        scrobbleLoopedTracks: false
    )
    expectEqual("first sighting imports only the current lastPlayedDate play", recoveredStarts.count, 1)
    expect("first sighting uses playback start when duration is known", recoveredStarts == [1_222], detail: "got \(recoveredStarts)")

    let conservativeStarts = recoveredPlaybackHistoryStartTimestamps(
        playCount: 15,
        previousPlayCount: 0,
        playedAt: 4_405,
        durationSeconds: 60,
        previousSeenPlayedAt: nil,
        preventDuplicates: true,
        scrobbleLoopedTracks: false
    )
    expectEqual("known play-count increases can recover all new plays", conservativeStarts.count, 15)
    expect("known play-count increases stagger timestamps", conservativeStarts == [3_505, 3_565, 3_625, 3_685, 3_745, 3_805, 3_865, 3_925, 3_985, 4_045, 4_105, 4_165, 4_225, 4_285, 4_345], detail: "got \(conservativeStarts)")

    let loopToggleStarts = recoveredPlaybackHistoryStartTimestamps(
        playCount: 20,
        previousPlayCount: nil,
        playedAt: 9_876,
        durationSeconds: 12,
        previousSeenPlayedAt: nil,
        preventDuplicates: true,
        scrobbleLoopedTracks: true
    )
    expectEqual("looped-track setting does not turn lifetime playCount into first-sighting imports", loopToggleStarts.count, 1)

    let samePlayedAtGrowthStarts = recoveredPlaybackHistoryStartTimestamps(
        playCount: 4,
        previousPlayCount: 3,
        playedAt: 1_200,
        durationSeconds: 200,
        previousSeenPlayedAt: 1_200,
        preventDuplicates: false,
        scrobbleLoopedTracks: false
    )
    expect("same playedAt growth imports only the new delta play", samePlayedAtGrowthStarts == [1_000], detail: "got \(samePlayedAtGrowthStarts)")

    let samePlayedAtMultiGrowthStarts = recoveredPlaybackHistoryStartTimestamps(
        playCount: 5,
        previousPlayCount: 3,
        playedAt: 1_200,
        durationSeconds: 200,
        previousSeenPlayedAt: 1_200,
        preventDuplicates: false,
        scrobbleLoopedTracks: false
    )
    expect("same playedAt multi-growth imports only the delta timeline", samePlayedAtMultiGrowthStarts == [800, 1_000], detail: "got \(samePlayedAtMultiGrowthStarts)")

    let unknownDurationStarts = recoveredPlaybackHistoryStartTimestamps(
        playCount: 1,
        previousPlayCount: nil,
        playedAt: 3_000,
        durationSeconds: nil,
        previousSeenPlayedAt: nil,
        preventDuplicates: false,
        scrobbleLoopedTracks: false
    )
    expect("unknown-duration first sighting falls back to Apple's timestamp", unknownDurationStarts == [3_000], detail: "got \(unknownDurationStarts)")

    section("Listening History · Edge cases")

    func productionPlaybackHistoryStartTimestamps(
        playedAt: Int,
        playCount: Int,
        durationSeconds: Double?
    ) -> [Int] {
        let count = max(playCount, 1)

        if let durationSeconds, durationSeconds > 0 {
            let spacingSeconds = max(Int(durationSeconds.rounded(.down)), 1)
            return (0..<count).map { index in
                max(1, playedAt - spacingSeconds * (count - index))
            }
        }

        guard count > 1 else { return [max(1, playedAt)] }

        return (0..<count).map { index in
            max(1, playedAt - (count - index - 1))
        }
    }

    expectEqual(
        "zero playCount is clamped to one import candidate",
        productionPlaybackHistoryStartTimestamps(playedAt: 500, playCount: 0, durationSeconds: 30),
        [470]
    )
    expectEqual(
        "negative playCount is clamped to one import candidate",
        productionPlaybackHistoryStartTimestamps(playedAt: 500, playCount: -4, durationSeconds: 30),
        [470]
    )
    expectEqual(
        "fractional durations are rounded down before spacing recovered plays",
        productionPlaybackHistoryStartTimestamps(playedAt: 1_000, playCount: 3, durationSeconds: 30.9),
        [910, 940, 970]
    )
    expectEqual(
        "sub-second positive durations still space candidates at least one second apart",
        productionPlaybackHistoryStartTimestamps(playedAt: 10, playCount: 3, durationSeconds: 0.4),
        [7, 8, 9]
    )
    expectEqual(
        "known-duration candidates are clamped to valid Last.fm timestamps",
        productionPlaybackHistoryStartTimestamps(playedAt: 2, playCount: 3, durationSeconds: 5),
        [1, 1, 1]
    )
    expectEqual(
        "unknown-duration recovered candidates are clamped near the Unix epoch",
        productionPlaybackHistoryStartTimestamps(playedAt: 2, playCount: 5, durationSeconds: nil),
        [1, 1, 1, 1, 2]
    )

    func playbackHistoryPlayedAt(
        startTimestamp: Int,
        originalPlayedAt: Int,
        durationSeconds: Double?
    ) -> Int {
        guard let durationSeconds, durationSeconds > 0 else {
            return originalPlayedAt
        }

        return startTimestamp + max(Int(durationSeconds.rounded(.down)), 1)
    }

    expectEqual(
        "candidate playedAt uses synthesized end time when duration is known",
        playbackHistoryPlayedAt(startTimestamp: 970, originalPlayedAt: 1_000, durationSeconds: 30.9),
        1_000
    )
    expectEqual(
        "candidate playedAt preserves Apple's timestamp when duration is unknown",
        playbackHistoryPlayedAt(startTimestamp: 999, originalPlayedAt: 1_050, durationSeconds: nil),
        1_050
    )
    expectEqual(
        "candidate playedAt uses at least one-second duration for tiny positive durations",
        playbackHistoryPlayedAt(startTimestamp: 9, originalPlayedAt: 10, durationSeconds: 0.4),
        10
    )

    struct FakeHistoryCandidate {
        let artist: String?
        let title: String?
        let playedAt: Int
        let previousSeenPlayedAt: Int?
        let playCount: Int
        let previousPlayCount: Int?
    }

    func shouldImportPlaybackHistoryCandidate(_ candidate: FakeHistoryCandidate, fetchCutoff: Int) -> Bool {
        let artist = candidate.artist ?? ""
        let title = candidate.title ?? ""
        guard !artist.isEmpty, !title.isEmpty else { return false }

        let playCutoff: Int = {
            if let previousSeenPlayedAt = candidate.previousSeenPlayedAt {
                return max(fetchCutoff, previousSeenPlayedAt)
            }
            return fetchCutoff
        }()
        let hasNewPlayedAt = candidate.playedAt > playCutoff
        let hasCountIncreaseAtSamePlayedAt = candidate.previousSeenPlayedAt == candidate.playedAt &&
            candidate.previousPlayCount.map { candidate.playCount > $0 } == true
        return hasNewPlayedAt || hasCountIncreaseAtSamePlayedAt
    }

    expect(
        "blank artist is skipped before cursor state changes",
        !shouldImportPlaybackHistoryCandidate(
            FakeHistoryCandidate(artist: "", title: "Song", playedAt: 2_001, previousSeenPlayedAt: nil, playCount: 1, previousPlayCount: nil),
            fetchCutoff: 2_000
        )
    )
    expect(
        "blank title is skipped before cursor state changes",
        !shouldImportPlaybackHistoryCandidate(
            FakeHistoryCandidate(artist: "Artist", title: nil, playedAt: 2_001, previousSeenPlayedAt: nil, playCount: 1, previousPlayCount: nil),
            fetchCutoff: 2_000
        )
    )
    expect(
        "play exactly at cutoff is skipped without a same-playedAt count increase",
        !shouldImportPlaybackHistoryCandidate(
            FakeHistoryCandidate(artist: "Artist", title: "Song", playedAt: 2_000, previousSeenPlayedAt: nil, playCount: 2, previousPlayCount: 1),
            fetchCutoff: 2_000
        )
    )
    expect(
        "per-track cursor can skip an older backfilled play after global fetch cutoff",
        !shouldImportPlaybackHistoryCandidate(
            FakeHistoryCandidate(artist: "Artist", title: "Song", playedAt: 2_100, previousSeenPlayedAt: 2_200, playCount: 5, previousPlayCount: 4),
            fetchCutoff: 2_000
        )
    )
    expect(
        "same playedAt with increased count is imported even at the per-track cursor",
        shouldImportPlaybackHistoryCandidate(
            FakeHistoryCandidate(artist: "Artist", title: "Song", playedAt: 2_200, previousSeenPlayedAt: 2_200, playCount: 5, previousPlayCount: 4),
            fetchCutoff: 2_000
        )
    )

    func shouldAdvancePlaybackHistoryCursor(candidateCount: Int, importedBeforeTrack: Int, maxItems: Int) -> Bool {
        var importedCount = importedBeforeTrack
        var processedAllCandidateTimestamps = true
        for _ in 0..<candidateCount {
            guard importedCount < maxItems else {
                processedAllCandidateTimestamps = false
                break
            }
            importedCount += 1
        }
        return processedAllCandidateTimestamps
    }

    expect("cursor advances when the full recovered timeline is processed",
           shouldAdvancePlaybackHistoryCursor(candidateCount: 3, importedBeforeTrack: 0, maxItems: 3))
    expect("cursor does not advance when the batch ends mid-timeline",
           !shouldAdvancePlaybackHistoryCursor(candidateCount: 4, importedBeforeTrack: 0, maxItems: 3))

    section("Listening History · Import state pruning")

    func pruneState(
        lastSeenByTrackID: [String: Int],
        playCountByTrackID: [String: Int],
        now: Int,
        retentionDays: Int = 14,
        maxEntries: Int = 2_500
    ) -> ([String: Int], [String: Int]) {
        let cutoff = now - retentionDays * 24 * 60 * 60
        var filteredLastSeen = lastSeenByTrackID.filter { $0.value >= cutoff }
        let allowedIDs = Set(filteredLastSeen.keys)
        var filteredPlayCount = playCountByTrackID.filter { allowedIDs.contains($0.key) }

        if filteredLastSeen.count > maxEntries {
            let newest = filteredLastSeen.sorted(by: { $0.value > $1.value }).prefix(maxEntries)
            let keepIDs = Set(newest.map(\.key))
            filteredLastSeen = filteredLastSeen.filter { keepIDs.contains($0.key) }
            filteredPlayCount = filteredPlayCount.filter { keepIDs.contains($0.key) }
        }

        return (filteredLastSeen, filteredPlayCount)
    }

    let pruneNow = 2_000_000_000
    let staleState = pruneState(
        lastSeenByTrackID: [
            "fresh": pruneNow - 60,
            "stale": pruneNow - (15 * 24 * 60 * 60)
        ],
        playCountByTrackID: [
            "fresh": 3,
            "stale": 8
        ],
        now: pruneNow
    )
    expectEqual("state pruning removes track cursors older than 14 days", Array(staleState.0.keys).sorted(), ["fresh"])
    expectEqual("state pruning drops play counts for removed cursors", Array(staleState.1.keys).sorted(), ["fresh"])

    let oversizedLastSeen = Dictionary(uniqueKeysWithValues: (0..<2_510).map { index in
        ("track-\(index)", pruneNow - index)
    })
    let oversizedPlayCounts = Dictionary(uniqueKeysWithValues: (0..<2_510).map { index in
        ("track-\(index)", index)
    })
    let oversizedState = pruneState(lastSeenByTrackID: oversizedLastSeen, playCountByTrackID: oversizedPlayCounts, now: pruneNow)
    expectEqual("state pruning trims tracked IDs to 2500", oversizedState.0.count, 2_500)
    expectEqual("state pruning trims play-count map to the same 2500 IDs", oversizedState.1.count, 2_500)
    expect("state pruning preserves the newest tracked ID", oversizedState.0.keys.contains("track-0"))
    expect("state pruning drops the oldest tracked ID", !oversizedState.0.keys.contains("track-2509"))

    func shouldProcessPlaybackHistoryCandidate(
        playedAt: Int,
        playCutoff: Int,
        previousSeenPlayedAt: Int?,
        playCount: Int,
        previousPlayCount: Int?
    ) -> Bool {
        let hasNewPlayedAt = playedAt > playCutoff
        let hasCountIncreaseAtSamePlayedAt = previousSeenPlayedAt == playedAt &&
            previousPlayCount.map { playCount > $0 } == true
        return hasNewPlayedAt || hasCountIncreaseAtSamePlayedAt
    }

    expect("same-minute candidate is still processed when playCount increases",
           shouldProcessPlaybackHistoryCandidate(playedAt: 2_000, playCutoff: 2_000, previousSeenPlayedAt: 2_000, playCount: 7, previousPlayCount: 5))
    expect("same-minute candidate is skipped when playCount is unchanged",
           !shouldProcessPlaybackHistoryCandidate(playedAt: 2_000, playCutoff: 2_000, previousSeenPlayedAt: 2_000, playCount: 7, previousPlayCount: 7))

    section("Listening History · Same-timestamp delta protection")

    func importedPlaybackHistoryStartsForSameTimestampGrowth(
        playedAt: Int,
        playCount: Int,
        previousPlayCount: Int?,
        durationSeconds: Int?,
        existingStarts: [Int]
    ) -> [Int] {
        let candidateStarts = recoveredPlaybackHistoryStartTimestamps(
            playCount: playCount,
            previousPlayCount: previousPlayCount,
            playedAt: playedAt,
            durationSeconds: durationSeconds,
            previousSeenPlayedAt: playedAt,
            preventDuplicates: true,
            scrobbleLoopedTracks: false
        )

        return candidateStarts.filter { candidate in
            !existingStarts.contains(where: { abs($0 - candidate) <= 3 })
        }
    }

    let sameTimestampDeltaOnlyStarts = importedPlaybackHistoryStartsForSameTimestampGrowth(
        playedAt: 1_200,
        playCount: 4,
        previousPlayCount: 3,
        durationSeconds: 200,
        existingStarts: [400, 600, 800]
    )
    expectEqual("same-timestamp growth only surfaces one new start", sameTimestampDeltaOnlyStarts, [1_000])

    let sameTimestampRescanStarts = importedPlaybackHistoryStartsForSameTimestampGrowth(
        playedAt: 1_200,
        playCount: 4,
        previousPlayCount: 4,
        durationSeconds: 200,
        existingStarts: [400, 600, 800, 1_000]
    )
    expectEqual("same-timestamp rescan imports nothing after state catches up", sameTimestampRescanStarts, [])

    let sameTimestampTwoPlayDeltaStarts = importedPlaybackHistoryStartsForSameTimestampGrowth(
        playedAt: 1_200,
        playCount: 5,
        previousPlayCount: 3,
        durationSeconds: 200,
        existingStarts: [400, 600]
    )
    expectEqual("same-timestamp two-play growth yields only two new starts", sameTimestampTwoPlayDeltaStarts, [800, 1_000])

    let sameTimestampLiveOverlapStarts = importedPlaybackHistoryStartsForSameTimestampGrowth(
        playedAt: 1_200,
        playCount: 4,
        previousPlayCount: 3,
        durationSeconds: 200,
        existingStarts: [1_000]
    )
    expectEqual("same-timestamp growth is fully suppressed when the new play already exists", sameTimestampLiveOverlapStarts, [])

    section("Listening History · Match counting against stored timestamps")

    struct FakeHistoryMatch {
        let dedupeKey: String
        let startTimestamp: Int
        let durationSeconds: Int?
        let style: String
    }

    func playbackHistoryImportMatchCount(
        items: [FakeHistoryMatch],
        key: String,
        startTimestamp: Int,
        playedAt: Int,
        exactTolerance: Int,
        playedTolerance: Int
    ) -> Int {
        let exactTol = max(0, exactTolerance)
        let playedTol = max(0, playedTolerance)

        return items.filter { item in
            guard item.dedupeKey == key else { return false }

            let exactMatch = abs(item.startTimestamp - startTimestamp) <= exactTol
            let directPlayedAtMatch = abs(item.startTimestamp - playedAt) <= playedTol

            switch item.style {
            case "history", "manual", "recentlyPlayed":
                return exactMatch || directPlayedAtMatch
            case "live":
                guard let durationSeconds = item.durationSeconds else { return exactMatch || directPlayedAtMatch }
                return exactMatch || abs((item.startTimestamp + durationSeconds) - playedAt) <= playedTol
            default:
                guard let durationSeconds = item.durationSeconds else { return exactMatch || directPlayedAtMatch }
                return exactMatch || directPlayedAtMatch || abs((item.startTimestamp + durationSeconds) - playedAt) <= playedTol
            }
        }.count
    }

    let exactMinuteMatches = [
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 1_000, durationSeconds: nil, style: "history"),
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 1_200, durationSeconds: nil, style: "history"),
    ]
    expectEqual(
        "staggered playback-history timestamps are counted individually",
        playbackHistoryImportMatchCount(items: exactMinuteMatches, key: "track-a", startTimestamp: 1_000, playedAt: 1_200, exactTolerance: 3, playedTolerance: 0),
        2
    )

    let crossSourceMatches = [
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 1_000, durationSeconds: 200, style: "live")
    ]
    let desiredImports = 3
    let existingCrossSourceMatches = playbackHistoryImportMatchCount(
        items: crossSourceMatches,
        key: "track-a",
        startTimestamp: 1_200,
        playedAt: 1_200,
        exactTolerance: 3,
        playedTolerance: 0
    )
    expectEqual("live scrobble overlap counts as exactly one existing match", existingCrossSourceMatches, 1)
    expectEqual("cross-source overlap suppresses only one recovered play", max(0, desiredImports - existingCrossSourceMatches), 2)

    let sameTimestampLiveDeltaMatches = [
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 1_000, durationSeconds: 200, style: "live")
    ]
    let sameTimestampLiveDeltaCandidates = [1_000]
    let survivingSameTimestampLiveDeltaCandidates = sameTimestampLiveDeltaCandidates.filter { candidateStart in
        playbackHistoryImportMatchCount(
            items: sameTimestampLiveDeltaMatches,
            key: "track-a",
            startTimestamp: candidateStart,
            playedAt: 1_200,
            exactTolerance: 3,
            playedTolerance: 0
        ) == 0
    }
    expectEqual("same-timestamp delta recovery is blocked by an existing live scrobble for that play", survivingSameTimestampLiveDeltaCandidates, [])

    let alreadyImported = [
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 2_400, durationSeconds: nil, style: "history"),
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 2_700, durationSeconds: nil, style: "history"),
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 3_000, durationSeconds: nil, style: "history"),
    ]
    let regeneratedCandidateStarts = [2_400, 2_700, 3_000]
    let existingCandidateMatches = regeneratedCandidateStarts.filter { candidateStart in
        playbackHistoryImportMatchCount(
            items: alreadyImported,
            key: "track-a",
            startTimestamp: candidateStart,
            playedAt: candidateStart,
            exactTolerance: 3,
            playedTolerance: 0
        ) > 0
    }.count
    expectEqual("re-running import sees every synthesized timestamp already present", existingCandidateMatches, 3)
    expectEqual("re-running import does not enqueue more when counts already match", max(0, 3 - existingCandidateMatches), 0)

    let edgeOriginMatches = [
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 4_000, durationSeconds: 200, style: "manual"),
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 4_200, durationSeconds: 200, style: "manual"),
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 4_400, durationSeconds: 200, style: "recentlyPlayed"),
        FakeHistoryMatch(dedupeKey: "track-b", startTimestamp: 4_000, durationSeconds: 200, style: "history"),
        FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 4_600, durationSeconds: nil, style: "live")
    ]
    expectEqual(
        "manual and recently-played direct timestamp matches suppress playback-history imports",
        playbackHistoryImportMatchCount(items: edgeOriginMatches, key: "track-a", startTimestamp: 4_200, playedAt: 4_200, exactTolerance: 3, playedTolerance: 0),
        1
    )
    expectEqual(
        "dedupe key mismatch never suppresses a listening-history import",
        playbackHistoryImportMatchCount(items: edgeOriginMatches, key: "track-b", startTimestamp: 4_200, playedAt: 4_200, exactTolerance: 3, playedTolerance: 0),
        0
    )
    expectEqual(
        "live items without duration do not end-match a playback-history playedAt timestamp",
        playbackHistoryImportMatchCount(items: edgeOriginMatches, key: "track-a", startTimestamp: 4_410, playedAt: 4_610, exactTolerance: 3, playedTolerance: 0),
        0
    )
    expectEqual(
        "negative duplicate tolerances behave as zero",
        playbackHistoryImportMatchCount(items: edgeOriginMatches, key: "track-a", startTimestamp: 4_001, playedAt: 4_001, exactTolerance: -10, playedTolerance: -10),
        0
    )
    expectEqual(
        "direct playedAt matching can be enabled for origin-less legacy backlog rows",
        playbackHistoryImportMatchCount(
            items: [FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 4_210, durationSeconds: nil, style: "legacy")],
            key: "track-a",
            startTimestamp: 4_000,
            playedAt: 4_210,
            exactTolerance: 3,
            playedTolerance: 0
        ),
        1
    )

    // ─── Dedup nearest-match selection ────────────────────────────────────────────
}
