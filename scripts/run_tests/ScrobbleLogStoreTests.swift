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

    let maxStoredEntries = 200
    let defaultDisplayLimit = 40
    let manualDisplayLimit = 30
    let maxEntryAgeSeconds = 45 * 24 * 60 * 60

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
    expectEqual("normalization removes entries older than 45 days", normalizedEntries([old, recent], now: now).map(\.id), ["recent"])

    let oversized = (0..<210).map { index in
        FakeLogEntry(id: "\(index)", source: "live", key: "track-\(index)", startTimestamp: now - index, scrobbledAt: now - index)
    }
    let trimmed = normalizedEntries(oversized, now: now)
    expectEqual("normalization trims stored log to 200 entries", trimmed.count, maxStoredEntries)
    expect("normalization preserves newest stored entry", trimmed.contains(where: { $0.id == "0" }))
    expect("normalization drops oldest excess entry", !trimmed.contains(where: { $0.id == "209" }))

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
        if source == "playbackHistory" {
            return startTimestamp
        }
        return scrobbledAt
    }

    expectEqual("playback-history rows display Apple's played timestamp", displayTimestamp(source: "playbackHistory", startTimestamp: 5_000, scrobbledAt: 6_000), 5_000)
    expectEqual("live rows display submission time", displayTimestamp(source: "live", startTimestamp: 5_000, scrobbledAt: 6_000), 6_000)
}
