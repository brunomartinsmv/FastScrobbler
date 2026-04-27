import Foundation

struct FakeScrobble { let dedupeKey: String; let startTimestamp: Int }

func runDedupTimestampToleranceTests() {
    // ─── Duplicate scrobble timestamp tolerance ───────────────────────────────────
    // Replicates containsSimilar from ScrobbleBacklog / ScrobbleLogStore.
    // Deduplication window: 10 seconds (tolerance = 10).

    section("Dedup · Timestamp tolerance (10s window)")

    func containsSimilar(items: [FakeScrobble], key: String, around ts: Int, tolerance: Int) -> Bool {
        let tol = max(0, tolerance)
        return items.contains(where: { $0.dedupeKey == key && abs($0.startTimestamp - ts) <= tol })
    }

    let existing = [FakeScrobble(dedupeKey: "track-a", startTimestamp: 1000)]

    expect("same track at T+5 is duplicate",    containsSimilar(items: existing, key: "track-a", around: 1005, tolerance: 10))
    expect("same track at T+10 is duplicate",   containsSimilar(items: existing, key: "track-a", around: 1010, tolerance: 10))
    expect("same track at T+11 is NOT dup",     !containsSimilar(items: existing, key: "track-a", around: 1011, tolerance: 10))
    expect("different track same ts is NOT dup",!containsSimilar(items: existing, key: "track-b", around: 1000, tolerance: 10))
    expect("same track at T-10 is duplicate",   containsSimilar(items: existing, key: "track-a", around: 990, tolerance: 10))
    expect("tolerance=0 only matches exact ts", containsSimilar(items: existing, key: "track-a", around: 1000, tolerance: 0))
    expect("tolerance=0 doesn't match T+1",     !containsSimilar(items: existing, key: "track-a", around: 1001, tolerance: 0))
    expect("negative tolerance clamps to 0",    !containsSimilar(items: existing, key: "track-a", around: 1001, tolerance: -5))
}

func runDedupNearestMatchTests() {
    section("Dedup · Nearest matching timestamp is selected")

    func mostSimilar(items: [FakeScrobble], key: String, around ts: Int, tolerance: Int) -> FakeScrobble? {
        let tol = max(0, tolerance)
        return items
            .filter { $0.dedupeKey == key && abs($0.startTimestamp - ts) <= tol }
            .min(by: { abs($0.startTimestamp - ts) < abs($1.startTimestamp - ts) })
    }

    let similarItems = [
        FakeScrobble(dedupeKey: "track-a", startTimestamp: 980),
        FakeScrobble(dedupeKey: "track-a", startTimestamp: 1008),
        FakeScrobble(dedupeKey: "track-a", startTimestamp: 1015),
        FakeScrobble(dedupeKey: "track-b", startTimestamp: 1001),
    ]

    expect("nearest item within tolerance is returned", mostSimilar(items: similarItems, key: "track-a", around: 1005, tolerance: 20)?.startTimestamp == 1008,
           detail: "got \(mostSimilar(items: similarItems, key: "track-a", around: 1005, tolerance: 20)?.startTimestamp ?? -1)")
    expect("out-of-window candidates return nil", mostSimilar(items: similarItems, key: "track-a", around: 1050, tolerance: 10) == nil)
    expect("different dedupeKey is ignored", mostSimilar(items: similarItems, key: "track-b", around: 1005, tolerance: 10)?.startTimestamp == 1001,
           detail: "got \(mostSimilar(items: similarItems, key: "track-b", around: 1005, tolerance: 10)?.startTimestamp ?? -1)")
}
