import Foundation

func runScrobbleLogStoreTests() {
    section("Scrobble Log · Retention, ordering, and helpers")

    struct FakeLogEntry: Equatable {
        let id: String
        let source: String
        let key: String
        let startTimestamp: Int
        let scrobbledAt: Int
    }

    let maxStoredEntries = 100
    let defaultDisplayLimit = 40
    let manualDisplayLimit = 30
    let maxEntryAgeSeconds = 21 * 24 * 60 * 60

    func mergeIdentity(for entry: FakeLogEntry) -> String {
        "\(entry.source)|\(entry.key)|\(entry.startTimestamp)"
    }

    func normalizedEntries(_ entries: [FakeLogEntry], now: Int) -> [FakeLogEntry] {
        let cutoff = now - maxEntryAgeSeconds
        var normalized = entries.filter { $0.scrobbledAt >= cutoff }
        normalized.sort {
            if $0.scrobbledAt == $1.scrobbledAt {
                return $0.startTimestamp > $1.startTimestamp
            }
            return $0.scrobbledAt > $1.scrobbledAt
        }
        if normalized.count > maxStoredEntries {
            normalized.removeLast(normalized.count - maxStoredEntries)
        }
        return normalized
    }

    func recentEntries(_ entries: [FakeLogEntry], limit: Int = defaultDisplayLimit) -> [FakeLogEntry] {
        Array(entries.prefix(max(0, limit)))
    }

    func manualEntries(_ entries: [FakeLogEntry], limit: Int = manualDisplayLimit) -> [FakeLogEntry] {
        Array(entries.filter { $0.source == "manual" }.prefix(max(0, limit)))
    }

    func mergeLogEntries(shared: [FakeLogEntry], legacy: [FakeLogEntry], now: Int) -> [FakeLogEntry] {
        var map: [String: FakeLogEntry] = [:]
        for entry in shared {
            map[mergeIdentity(for: entry)] = entry
        }
        for entry in legacy {
            let key = mergeIdentity(for: entry)
            if let existing = map[key] {
                if entry.scrobbledAt > existing.scrobbledAt {
                    map[key] = entry
                }
            } else {
                map[key] = entry
            }
        }
        return normalizedEntries(Array(map.values), now: now)
    }

    let now = 2_000_000_000
    let old = FakeLogEntry(id: "old", source: "live", key: "track-old", startTimestamp: now - maxEntryAgeSeconds - 1, scrobbledAt: now - maxEntryAgeSeconds - 1)
    let recent = FakeLogEntry(id: "recent", source: "live", key: "track-recent", startTimestamp: now - 60, scrobbledAt: now - 60)
    expectEqual("normalization removes entries older than 21 days", normalizedEntries([old, recent], now: now).map(\.id), ["recent"])

    let oversized = (0..<110).map { index in
        FakeLogEntry(id: "\(index)", source: "live", key: "track-\(index)", startTimestamp: now - index, scrobbledAt: now - index)
    }
    let trimmed = normalizedEntries(oversized, now: now)
    expectEqual("normalization trims stored log to 100 entries", trimmed.count, maxStoredEntries)
    expect("normalization preserves newest stored entry", trimmed.contains(where: { $0.id == "0" }))
    expect("normalization drops oldest excess entry", !trimmed.contains(where: { $0.id == "109" }))

    let sameSubmitTimeOlderStart = FakeLogEntry(id: "older-start", source: "live", key: "track-a", startTimestamp: now - 500, scrobbledAt: now - 100)
    let newestSubmitTime = FakeLogEntry(id: "newest-submit", source: "live", key: "track-b", startTimestamp: now - 600, scrobbledAt: now - 50)
    let sameSubmitTimeNewerStart = FakeLogEntry(id: "newer-start", source: "live", key: "track-c", startTimestamp: now - 400, scrobbledAt: now - 100)
    expectEqual(
        "normalization sorts by scrobbledAt, then startTimestamp",
        normalizedEntries([sameSubmitTimeOlderStart, newestSubmitTime, sameSubmitTimeNewerStart], now: now).map(\.id),
        ["newest-submit", "newer-start", "older-start"]
    )

    let helperEntries = (0..<70).map { index in
        FakeLogEntry(
            id: "\(index)",
            source: index % 2 == 0 ? "manual" : "live",
            key: "track-\(index)",
            startTimestamp: now - index,
            scrobbledAt: now - index
        )
    }
    expectEqual("recentEntries uses the 40-entry default display limit", recentEntries(helperEntries).count, defaultDisplayLimit)
    expectEqual("manualEntries filters manual rows before applying the 30-entry limit", manualEntries(helperEntries).count, manualDisplayLimit)
    expectEqual("negative helper limits return no entries", recentEntries(helperEntries, limit: -1).count, 0)

    section("Scrobble Log · Merge identity")

    let shared = FakeLogEntry(id: "shared-id", source: "live", key: "track-a", startTimestamp: now - 4_000, scrobbledAt: now - 10)
    let legacySameScrobble = FakeLogEntry(id: "legacy-different-id", source: "live", key: "track-a", startTimestamp: now - 4_000, scrobbledAt: now - 8)
    let mergedSameScrobble = mergeLogEntries(shared: [shared], legacy: [legacySameScrobble], now: now)
    expectEqual("merge collapses same source, track, and timestamp even with different UUIDs", mergedSameScrobble.count, 1)
    expectEqual("merge keeps newer scrobbledAt for duplicate identities", mergedSameScrobble.first?.id ?? "", "legacy-different-id")

    let legacyDifferentSource = FakeLogEntry(id: "manual-id", source: "manual", key: "track-a", startTimestamp: now - 4_000, scrobbledAt: now - 7)
    let mergedDifferentSource = mergeLogEntries(shared: [shared], legacy: [legacyDifferentSource], now: now)
    expectEqual("merge preserves same track and timestamp from a different source", mergedDifferentSource.count, 2)

    section("Scrobble Log · Record duplicate policy")

    func shouldRecord(existing: [FakeLogEntry], candidate: FakeLogEntry) -> Bool {
        if candidate.source != "playbackHistory",
           existing.contains(where: { $0.startTimestamp == candidate.startTimestamp && $0.key == candidate.key }) {
            return false
        }
        return true
    }

    let duplicateLive = FakeLogEntry(id: "dup", source: "live", key: "track-a", startTimestamp: now - 4_000, scrobbledAt: now - 6)
    let duplicatePlaybackHistory = FakeLogEntry(id: "history-dup", source: "playbackHistory", key: "track-a", startTimestamp: now - 4_000, scrobbledAt: now - 5)
    expect("record rejects non-playback-history exact duplicates", !shouldRecord(existing: [shared], candidate: duplicateLive))
    expect("record allows playback-history exact duplicates", shouldRecord(existing: [shared], candidate: duplicatePlaybackHistory))

    section("Scrobble Log · Display timestamp source")

    func displayTimestamp(source: String, startTimestamp: Int, scrobbledAt: Int) -> Int {
        if source == "playbackHistory" || source == "recentlyPlayed" {
            return startTimestamp
        }
        return scrobbledAt
    }

    expectEqual("playback-history rows display Apple's played timestamp", displayTimestamp(source: "playbackHistory", startTimestamp: 5_000, scrobbledAt: 6_000), 5_000)
    expectEqual("recently-played rows display synthesized play timestamp", displayTimestamp(source: "recentlyPlayed", startTimestamp: 5_100, scrobbledAt: 6_000), 5_100)
    expectEqual("live rows display submission time", displayTimestamp(source: "live", startTimestamp: 5_000, scrobbledAt: 6_000), 6_000)

    section("Scrobble Log · Compact persistence migration")

    struct FullTrack: Codable {
        let artist: String
        let title: String
        let album: String?
        let albumArtist: String?
        let durationSeconds: Double?
        let usesFallbackDuration: Bool?
        let persistentID: UInt64?
        let playbackStoreID: String?
        let isCompilation: Bool?
    }

    struct LegacyEntry: Codable {
        let id: UUID
        let track: FullTrack
        let startTimestamp: Int
        let scrobbledAt: Int
        let source: String
        let lovedOnLastFM: Bool?
    }

    struct CompactTrack: Codable {
        let a: String
        let t: String
        let al: String?
        let aa: String?
        let d: Double?
        let uf: Bool?
        let p: UInt64?
        let ps: String?
        let ic: Bool?
    }

    struct CompactEntry: Codable {
        let i: UUID
        let t: CompactTrack
        let s: Int
        let c: Int
        let o: String
        let l: Bool?
    }

    let legacyEntries = (0..<12).map { index in
        LegacyEntry(
            id: UUID(uuidString: "10000000-0000-0000-0000-\(String(format: "%012d", index))") ?? UUID(),
            track: FullTrack(
                artist: "Artist \(index)",
                title: "Song \(index)",
                album: "Album \(index)",
                albumArtist: "Album Artist \(index)",
                durationSeconds: 240,
                usesFallbackDuration: false,
                persistentID: UInt64(index + 1),
                playbackStoreID: "store-\(index)",
                isCompilation: false
            ),
            startTimestamp: 40_000 + index,
            scrobbledAt: 50_000 + index,
            source: index.isMultiple(of: 2) ? "live" : "manual",
            lovedOnLastFM: index.isMultiple(of: 3)
        )
    }
    let compactEntries = legacyEntries.map { entry in
        CompactEntry(
            i: entry.id,
            t: CompactTrack(
                a: entry.track.artist,
                t: entry.track.title,
                al: entry.track.album,
                aa: entry.track.albumArtist,
                d: entry.track.durationSeconds,
                uf: entry.track.usesFallbackDuration,
                p: entry.track.persistentID,
                ps: entry.track.playbackStoreID,
                ic: entry.track.isCompilation
            ),
            s: entry.startTimestamp,
            c: entry.scrobbledAt,
            o: entry.source,
            l: entry.lovedOnLastFM
        )
    }

    let encoder = JSONEncoder()
    let legacyData = try! encoder.encode(legacyEntries)
    let compactData = try! encoder.encode(compactEntries)
    expect("compact scrobble-log persistence shrinks representative payloads", compactData.count < legacyData.count, detail: "legacy=\(legacyData.count), compact=\(compactData.count)")
}
