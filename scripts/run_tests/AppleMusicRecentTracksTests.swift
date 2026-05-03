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

    struct RecentTrackCandidate: Equatable {
        let id: String
        let artist: String
        let title: String
        let album: String?
        let durationSeconds: Double
        let startTimestamp: Int
        let playedAtTimestamp: Int
    }

    enum RecentImportStatus: String {
        case idle
        case disabled
        case authorizationUnavailable
        case fetchFailed
        case seeded
        case noRecentTracks
        case noNewTracks
        case imported
        case skippedDuplicatesOnly
    }

    struct RecentImportState: Equatable {
        var hasSeeded = false
        var recentTrackIDs: [String] = []
        var lastFetchCount = 0
        var lastImportedCount = 0
        var lastSkippedDuplicateCount = 0
        var lastStatus: RecentImportStatus = .idle
    }

    func unseenPrefix(fetchedIDs: [String], knownIDs: [String], hasSeeded: Bool) -> [String] {
        guard hasSeeded else { return [] }
        let known = Set(knownIDs)
        return Array(fetchedIDs.prefix { !known.contains($0) })
    }

    func mergeRecentIDs(newIDs: [String], existingIDs: [String], limit: Int = 120) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for id in newIDs + existingIDs {
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            merged.append(id)
            if merged.count >= limit { break }
        }
        return merged
    }

    func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func synthesizedCandidates(from tracks: [RecentTrackFixture], scanStartedAt: Int) -> [RecentTrackCandidate] {
        var estimatedEndAt = Double(scanStartedAt)
        var newestToOldest: [RecentTrackCandidate] = []

        for track in tracks {
            guard let artist = normalized(track.artist),
                  let title = normalized(track.title),
                  let durationMillis = track.durationMillis,
                  durationMillis > 0
            else {
                continue
            }

            let durationSeconds = Double(durationMillis) / 1000
            let startedAt = estimatedEndAt - durationSeconds
            newestToOldest.append(
                RecentTrackCandidate(
                    id: track.id,
                    artist: artist,
                    title: title,
                    album: normalized(track.album),
                    durationSeconds: durationSeconds,
                    startTimestamp: max(1, Int(floor(startedAt))),
                    playedAtTimestamp: Int(floor(estimatedEndAt))
                )
            )
            estimatedEndAt = startedAt
        }

        return newestToOldest.reversed()
    }

    func shouldImportCandidate(
        existingMatchCount: Int,
        hasSameTrackDuplicate: Bool = false,
        startTimestamp: Int,
        scanStartedAt: Int,
        maxAgeSeconds: Int = 14 * 24 * 60 * 60
    ) -> Bool {
        guard startTimestamp >= scanStartedAt - maxAgeSeconds else { return false }
        guard !hasSameTrackDuplicate else { return false }
        return existingMatchCount == 0
    }

    func shouldRunAppleMusicAPIImporter(isEnabled: Bool) -> Bool {
        isEnabled
    }

    func apiDuplicateToleranceSeconds(durationSeconds: Double?) -> Int {
        max(10 * 60, Int((durationSeconds ?? 0).rounded(.up)) + 4 * 60)
    }

    func hasSameTrackDuplicate(
        candidateStart: Int,
        candidateDuration: Double?,
        existingStart: Int?,
        sameTrack: Bool
    ) -> Bool {
        guard sameTrack, let existingStart else { return false }
        return abs(existingStart - candidateStart) <= apiDuplicateToleranceSeconds(durationSeconds: candidateDuration)
    }

    func resetRecentImportState() -> RecentImportState {
        RecentImportState()
    }

    func statusAfterImport(resourcesCount: Int, importedCount: Int, skippedDuplicateCount: Int, hadCandidates: Bool) -> RecentImportStatus {
        if resourcesCount == 0 { return .noRecentTracks }
        if importedCount > 0 { return .imported }
        if skippedDuplicateCount > 0 && hadCandidates { return .skippedDuplicatesOnly }
        return .noNewTracks
    }

    func shouldMarkFavorite(playbackStoreID: String?, favoriteStoreIDs: Set<String>) -> Bool {
        guard let playbackStoreID, !playbackStoreID.isEmpty else { return false }
        return favoriteStoreIDs.contains(playbackStoreID)
    }

    struct SimScanResult {
        let importedCount: Int
        let importedRecentTrackCount: Int
        let flushedPlaybackHistoryCount: Int
        let flushedRecentTrackCount: Int
        let skippedDuplicateCount: Int

        var totalImportedCount: Int { importedCount + importedRecentTrackCount }
        var totalFlushedCount: Int { flushedPlaybackHistoryCount + flushedRecentTrackCount }
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

    expectEqual(
        "scan with no overlap imports all returned recent tracks",
        unseenPrefix(fetchedIDs: ["a", "b"], knownIDs: ["x", "y"], hasSeeded: true),
        ["a", "b"]
    )

    expectEqual(
        "merged state keeps newest IDs first and removes duplicates",
        mergeRecentIDs(newIDs: ["n1", "n2", "old"], existingIDs: ["old", "older"]),
        ["n1", "n2", "old", "older"]
    )

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
    expectEqual("middle track preserves synthesized end time", synthesized[1].playedAtTimestamp, 970)

    let filtered = synthesizedCandidates(
        from: [
            RecentTrackFixture(id: "blankArtist", artist: " ", title: "Song", album: nil, durationMillis: 10_000),
            RecentTrackFixture(id: "blankTitle", artist: "Artist", title: nil, album: nil, durationMillis: 10_000),
            RecentTrackFixture(id: "missingDuration", artist: "Artist", title: "Song", album: nil, durationMillis: nil),
            RecentTrackFixture(id: "zeroDuration", artist: "Artist", title: "Song", album: nil, durationMillis: 0),
            RecentTrackFixture(id: "valid", artist: " Artist ", title: " Song ", album: " Album ", durationMillis: 10_000),
        ],
        scanStartedAt: 500
    )
    expectEqual("invalid recent track metadata is skipped", filtered.map(\.id), ["valid"])
    expectEqual("valid recent track metadata is trimmed", [filtered[0].artist, filtered[0].title, filtered[0].album ?? ""], ["Artist", "Song", "Album"])

    section("Apple Music Recent Tracks · duplicate and result accounting")

    expect("candidate without existing backlog/log match is importable", shouldImportCandidate(existingMatchCount: 0, startTimestamp: 10_000, scanStartedAt: 10_100))
    expect("candidate with existing backlog/log match is skipped", !shouldImportCandidate(existingMatchCount: 1, startTimestamp: 10_000, scanStartedAt: 10_100))
    expect("candidate older than Last.fm's two-week window is skipped", !shouldImportCandidate(existingMatchCount: 0, startTimestamp: 1, scanStartedAt: 14 * 24 * 60 * 60 + 2))
    expect("Apple Music API importer does not run when setting is off", !shouldRunAppleMusicAPIImporter(isEnabled: false))
    expect("Apple Music API importer runs when setting is on", shouldRunAppleMusicAPIImporter(isEnabled: true))
    expectEqual("API duplicate tolerance is at least ten minutes", apiDuplicateToleranceSeconds(durationSeconds: 180), 600)
    expectEqual("API duplicate tolerance expands for long tracks", apiDuplicateToleranceSeconds(durationSeconds: 900), 1_140)
    expect("same-track live/log/backlog entry inside API window suppresses import",
           hasSameTrackDuplicate(candidateStart: 10_000, candidateDuration: 180, existingStart: 10_550, sameTrack: true))
    expect("same-track entry outside API window does not suppress import",
           !hasSameTrackDuplicate(candidateStart: 10_000, candidateDuration: 180, existingStart: 10_601, sameTrack: true))
    expect("different track inside API window does not suppress import",
           !hasSameTrackDuplicate(candidateStart: 10_000, candidateDuration: 180, existingStart: 10_300, sameTrack: false))
    expect("candidate with same-track API duplicate is skipped",
           !shouldImportCandidate(existingMatchCount: 0, hasSameTrackDuplicate: true, startTimestamp: 10_000, scanStartedAt: 10_100))

    section("Apple Music Recent Tracks · state lifecycle and diagnostics")

    let resetState = resetRecentImportState()
    expect("reset clears seeded state", !resetState.hasSeeded)
    expectEqual("reset clears remembered recent track IDs", resetState.recentTrackIDs, [])
    expectEqual("reset clears last fetch count", resetState.lastFetchCount, 0)
    expectEqual("reset clears last imported count", resetState.lastImportedCount, 0)
    expectEqual("reset clears last skipped duplicate count", resetState.lastSkippedDuplicateCount, 0)
    expectEqual("reset restores idle importer status", resetState.lastStatus, .idle)
    expectEqual("successful import status is reported", statusAfterImport(resourcesCount: 5, importedCount: 2, skippedDuplicateCount: 1, hadCandidates: true), .imported)
    expectEqual("duplicate-only pass is reported", statusAfterImport(resourcesCount: 5, importedCount: 0, skippedDuplicateCount: 3, hadCandidates: true), .skippedDuplicatesOnly)
    expectEqual("empty API response is reported separately", statusAfterImport(resourcesCount: 0, importedCount: 0, skippedDuplicateCount: 0, hadCandidates: false), .noRecentTracks)
    expectEqual("known-only response is reported as no new tracks", statusAfterImport(resourcesCount: 5, importedCount: 0, skippedDuplicateCount: 0, hadCandidates: false), .noNewTracks)

    section("Apple Music Recent Tracks · favorite parity")

    expect("favorite parity uses playback store ID matches", shouldMarkFavorite(playbackStoreID: "track-123", favoriteStoreIDs: ["track-123"]))
    expect("favorite parity ignores missing playback store IDs", !shouldMarkFavorite(playbackStoreID: nil, favoriteStoreIDs: ["track-123"]))
    expect("favorite parity does not mark unrelated tracks", !shouldMarkFavorite(playbackStoreID: "track-999", favoriteStoreIDs: ["track-123"]))

    let manualResult = SimScanResult(
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
