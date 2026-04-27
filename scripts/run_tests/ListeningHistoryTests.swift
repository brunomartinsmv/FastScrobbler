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
        let allowRepeatScrobbles = !preventDuplicates || scrobbleLoopedTracks
        let delta: Int = {
            guard let previousPlayCount else {
                if allowRepeatScrobbles {
                    return max(playCount, 1)
                }
                return 1
            }
            let d = playCount - previousPlayCount
            if d > 0 { return d }
            return 1
        }()

        let playsToImport: Int = {
            if !allowRepeatScrobbles {
                return min(max(delta, 1), 5)
            }
            return max(delta, 1)
        }()

        let synthesizedPlayCount =
            previousSeenPlayedAt == playedAt
                ? max(playCount, 1)
                : playsToImport

        guard synthesizedPlayCount > 1 else { return [playedAt] }

        if let durationSeconds, durationSeconds > 0 {
            return (0..<synthesizedPlayCount).map { index in
                playedAt - durationSeconds * (synthesizedPlayCount - index)
            }
        }

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
    expectEqual("first sighting imports full playCount when duplicate prevention is OFF", recoveredStarts.count, 20)
    expectEqual("recovered repeats synthesize distinct timestamps", Set(recoveredStarts).count, 20)
    expect("latest synthesized repeat ends at Apple's playedAt", recoveredStarts.last == 1_222, detail: "got \(recoveredStarts.suffix(3))")

    let conservativeStarts = recoveredPlaybackHistoryStartTimestamps(
        playCount: 15,
        previousPlayCount: 0,
        playedAt: 4_405,
        durationSeconds: 60,
        previousSeenPlayedAt: nil,
        preventDuplicates: true,
        scrobbleLoopedTracks: false
    )
    expectEqual("duplicate prevention ON keeps conservative 5-play cap", conservativeStarts.count, 5)
    expect("conservative recovery also staggers timestamps", conservativeStarts == [4_105, 4_165, 4_225, 4_285, 4_345], detail: "got \(conservativeStarts)")

    let loopToggleStarts = recoveredPlaybackHistoryStartTimestamps(
        playCount: 20,
        previousPlayCount: nil,
        playedAt: 9_876,
        durationSeconds: 12,
        previousSeenPlayedAt: nil,
        preventDuplicates: true,
        scrobbleLoopedTracks: true
    )
    expectEqual("looped-track setting also enables full-count history recovery", loopToggleStarts.count, 20)

    let samePlayedAtGrowthStarts = recoveredPlaybackHistoryStartTimestamps(
        playCount: 4,
        previousPlayCount: 3,
        playedAt: 1_200,
        durationSeconds: 200,
        previousSeenPlayedAt: 1_200,
        preventDuplicates: false,
        scrobbleLoopedTracks: false
    )
    expect("same playedAt growth regenerates the full synthesized timeline", samePlayedAtGrowthStarts == [400, 600, 800, 1000], detail: "got \(samePlayedAtGrowthStarts)")

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
            case "history", "manual":
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

    // ─── Dedup nearest-match selection ────────────────────────────────────────────
}
