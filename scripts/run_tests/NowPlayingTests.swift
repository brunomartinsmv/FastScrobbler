import Foundation

func runNowPlayingRateLimitTests() {
    // ─── Now-playing rate limit ───────────────────────────────────────────────────
    // Replicates maybeSendNowPlaying guard from ScrobbleEngine.swift: < 10s → skip.

    section("Engine · Now-playing update rate limit (10s)")

    func shouldSendNowPlaying(lastSentAt: Date?, now: Date) -> Bool {
        if let last = lastSentAt, now.timeIntervalSince(last) < 10 { return false }
        return true
    }

    let np0 = Date()
    expect("first update allowed (nil last)",         shouldSendNowPlaying(lastSentAt: nil, now: np0))
    expect("update 5s after is blocked",              !shouldSendNowPlaying(lastSentAt: np0, now: np0.addingTimeInterval(5)))
    expect("update 9.9s after is blocked",            !shouldSendNowPlaying(lastSentAt: np0, now: np0.addingTimeInterval(9.9)))
    expect("update exactly 10s after is allowed",     shouldSendNowPlaying(lastSentAt: np0, now: np0.addingTimeInterval(10)))
    expect("update 15s after is allowed",             shouldSendNowPlaying(lastSentAt: np0, now: np0.addingTimeInterval(15)))
}
