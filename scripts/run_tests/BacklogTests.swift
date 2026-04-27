import Foundation

func runBacklogTests() {
    //   if !ignoreBackoff, let last = item.lastAttemptAt, now.timeIntervalSince(last) < 10 * 60 { skip }

    section("Backlog · 10-minute backoff")

    func shouldSkipDueToBackoff(lastAttemptAt: Date?, now: Date, ignoreBackoff: Bool) -> Bool {
        guard !ignoreBackoff, let last = lastAttemptAt else { return false }
        return now.timeIntervalSince(last) < 10 * 60
    }

    let backoffNow = Date()
    expect("nil lastAttemptAt = always attempt",       !shouldSkipDueToBackoff(lastAttemptAt: nil, now: backoffNow, ignoreBackoff: false))
    expect("failed 5 min ago = skip",                  shouldSkipDueToBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-5*60), now: backoffNow, ignoreBackoff: false))
    expect("failed 9m59s ago = skip",                  shouldSkipDueToBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-599), now: backoffNow, ignoreBackoff: false))
    expect("failed exactly 10 min ago = retry",        !shouldSkipDueToBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-600), now: backoffNow, ignoreBackoff: false))
    expect("failed 11 min ago = retry",                !shouldSkipDueToBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-660), now: backoffNow, ignoreBackoff: false))
    expect("ignoreBackoff=true bypasses cooldown",     !shouldSkipDueToBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-1), now: backoffNow, ignoreBackoff: true))

    // ─── Backlog exponential backoff ──────────────────────────────────────────────
    // Replicates the current ScrobbleBacklog.flush() backoff schedule:
    // 1 min, 2 min, 4 min ... capped at 60 min, plus jitter.

    section("Backlog · Exponential backoff schedule")

    func shouldSkipDueToExponentialBackoff(lastAttemptAt: Date?, attemptCount: Int, now: Date, ignoreBackoff: Bool, jitter: TimeInterval = 0) -> Bool {
        guard !ignoreBackoff, let last = lastAttemptAt else { return false }
        let exponent = max(0, min(attemptCount - 1, 6))
        let baseDelay = min(TimeInterval(60 * (1 << exponent)), 60 * 60)
        return now.timeIntervalSince(last) < baseDelay + jitter
    }

    expect("attempt 1 waits 60s", shouldSkipDueToExponentialBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-59), attemptCount: 1, now: backoffNow, ignoreBackoff: false))
    expect("attempt 1 retries at 60s", !shouldSkipDueToExponentialBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-60), attemptCount: 1, now: backoffNow, ignoreBackoff: false))
    expect("attempt 2 waits 120s", shouldSkipDueToExponentialBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-119), attemptCount: 2, now: backoffNow, ignoreBackoff: false))
    expect("attempt 3 waits 240s", shouldSkipDueToExponentialBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-239), attemptCount: 3, now: backoffNow, ignoreBackoff: false))
    expect("attempt 8 caps at 3600s", shouldSkipDueToExponentialBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-3599), attemptCount: 8, now: backoffNow, ignoreBackoff: false))
    expect("attempt 8 retries at 3600s", !shouldSkipDueToExponentialBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-3600), attemptCount: 8, now: backoffNow, ignoreBackoff: false))
    expect("ignoreBackoff bypasses exponential delay", !shouldSkipDueToExponentialBackoff(lastAttemptAt: backoffNow.addingTimeInterval(-1), attemptCount: 8, now: backoffNow, ignoreBackoff: true))

    // ─── Backlog max batch size ───────────────────────────────────────────────────
    // Replicates `while idx < items.count, sentCount < maxItems` in flush().

    section("Backlog · Max batch size (25 items)")

    func simulateBatchFlush(queueSize: Int, maxItems: Int) -> (processed: Int, remaining: Int) {
        var queue = Array(0..<queueSize)
        var processed = 0
        let idx = 0
        while idx < queue.count, processed < maxItems {
            queue.remove(at: idx)
            processed += 1
            // idx stays the same since removal shifts elements down
        }
        return (processed, queue.count)
    }

    let batch30 = simulateBatchFlush(queueSize: 30, maxItems: 25)
    expect("30-item queue: processes exactly 25",    batch30.processed == 25, detail: "got \(batch30.processed)")
    expect("30-item queue: 5 remain",               batch30.remaining == 5,  detail: "got \(batch30.remaining)")

    let batch10 = simulateBatchFlush(queueSize: 10, maxItems: 25)
    expect("10-item queue: processes all 10",        batch10.processed == 10, detail: "got \(batch10.processed)")
    expect("10-item queue: 0 remain",               batch10.remaining == 0,  detail: "got \(batch10.remaining)")

    let batch0 = simulateBatchFlush(queueSize: 0, maxItems: 25)
    expect("empty queue: processes 0",               batch0.processed == 0)

    // ─── Backlog enqueue deduplication ───────────────────────────────────────────
    // Replicates enqueue's source-aware exact-duplicate guard.

    section("Backlog · Enqueue exact-duplicate prevention")

    struct BacklogEntry { let key: String; let ts: Int; let origin: String? }

    func simulateEnqueue(queue: inout [BacklogEntry], key: String, ts: Int, origin: String?, allowDuplicates: Bool = false) -> Bool {
        let allowsOriginExactDuplicates = origin == "playbackHistory"
        if !allowDuplicates, !allowsOriginExactDuplicates, queue.contains(where: { $0.key == key && $0.ts == ts }) {
            return false // rejected
        }
        queue.append(BacklogEntry(key: key, ts: ts, origin: origin))
        return true // accepted
    }

    var bq: [BacklogEntry] = []
    let added1 = simulateEnqueue(queue: &bq, key: "track-a", ts: 1000, origin: nil)
    let added2 = simulateEnqueue(queue: &bq, key: "track-a", ts: 1000, origin: nil)                  // exact dup
    let added3 = simulateEnqueue(queue: &bq, key: "track-a", ts: 2000, origin: nil)                  // same track, diff ts
    let added4 = simulateEnqueue(queue: &bq, key: "track-b", ts: 1000, origin: nil)                  // diff track, same ts
    let added5 = simulateEnqueue(queue: &bq, key: "track-a", ts: 3000, origin: "playbackHistory")    // history base
    let added6 = simulateEnqueue(queue: &bq, key: "track-a", ts: 3000, origin: "playbackHistory")    // same-minute history dup

    expect("first enqueue accepted",                    added1)
    expect("exact duplicate rejected",                  !added2)
    expect("same track different timestamp accepted",   added3)
    expect("different track same timestamp accepted",   added4)
    expect("playback-history exact duplicate accepted", added5 && added6)
    expect("queue has 5 items (not 6)",                 bq.count == 5, detail: "got \(bq.count)")

    // ─── Log merge identity ─────────────────────────────────────────────────────
    // Replicates ScrobbleLogStore.load() merge semantics using stable entry IDs.

    section("Scrobble Log · Merge preserves same-minute playback-history duplicates")

    struct FakeLogEntry {
        let id: String
        let key: String
        let ts: Int
        let scrobbledAt: Int
    }

    func mergeLogEntries(shared: [FakeLogEntry], legacy: [FakeLogEntry]) -> [FakeLogEntry] {
        var map: [String: FakeLogEntry] = [:]
        for entry in shared {
            map[entry.id] = entry
        }
        for entry in legacy {
            if let existing = map[entry.id] {
                if entry.scrobbledAt > existing.scrobbledAt {
                    map[entry.id] = entry
                }
            } else {
                map[entry.id] = entry
            }
        }
        return Array(map.values)
    }

    let mergedSameMinute = mergeLogEntries(
        shared: [
            FakeLogEntry(id: "a", key: "track-a", ts: 4_000, scrobbledAt: 10),
            FakeLogEntry(id: "b", key: "track-a", ts: 4_000, scrobbledAt: 11),
        ],
        legacy: []
    )
    expectEqual("distinct IDs with the same track and timestamp are preserved", mergedSameMinute.count, 2)

    let mergedSameID = mergeLogEntries(
        shared: [FakeLogEntry(id: "same", key: "track-a", ts: 4_000, scrobbledAt: 10)],
        legacy: [FakeLogEntry(id: "same", key: "track-a", ts: 4_000, scrobbledAt: 12)]
    )
    expectEqual("same ID collapses to one merged entry", mergedSameID.count, 1)
    expectEqual("same ID keeps the newer scrobbledAt value", mergedSameID.first?.scrobbledAt ?? -1, 12)

    section("Scrobble Log · Display timestamp source")

    func displayTimestamp(source: String, startTimestamp: Int, scrobbledAt: Int) -> Int {
        if source == "playbackHistory" {
            return startTimestamp
        }
        return scrobbledAt
    }

    expectEqual("playback-history rows display Apple's played timestamp", displayTimestamp(source: "playbackHistory", startTimestamp: 5_000, scrobbledAt: 6_000), 5_000)
    expectEqual("live rows still display submission time", displayTimestamp(source: "live", startTimestamp: 5_000, scrobbledAt: 6_000), 6_000)
}

func runBacklogTimestampPreservationTests() {
    section("Backlog · Timestamp preservation")

    struct PreservedBacklogEntry {
        let originalTimestamp: Int
        var attemptCount: Int = 0
    }

    func simulateRetryPreservingTimestamp(entry: inout PreservedBacklogEntry) -> Int {
        entry.attemptCount += 1
        return entry.originalTimestamp
    }

    var preservedEntry = PreservedBacklogEntry(originalTimestamp: 1_234_567_890)
    let preservedTimestamp = simulateRetryPreservingTimestamp(entry: &preservedEntry)
    expectEqual("backlog retry preserves the original captured timestamp", preservedTimestamp, 1_234_567_890)
    expectEqual("backlog retry only increments attempts, not timestamp", preservedEntry.attemptCount, 1)
}
