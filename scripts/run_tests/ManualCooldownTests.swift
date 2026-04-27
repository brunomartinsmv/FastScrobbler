import Foundation

func runManualCooldownTests() {
    // ─── 1d: Manual scrobble rate-limit logic ─────────────────────────────────────

    section("1d · Manual scrobble rate limit — 3-second cooldown")

    // Simulate the guard condition used in ScrobbleEngine.scrobbleNow:
    //   if let last = lastManualScrobbleAttemptAt, now.timeIntervalSince(last) < 3 { return }
    func shouldAllowScrobble(last: Date?, now: Date) -> Bool {
        if let last = last, now.timeIntervalSince(last) < 3 { return false }
        return true
    }

    let t0 = Date()
    expect("first tap always allowed (nil last)", shouldAllowScrobble(last: nil, now: t0))
    expect("tap 1s after is blocked", !shouldAllowScrobble(last: t0, now: t0.addingTimeInterval(1)))
    expect("tap 2.9s after is blocked", !shouldAllowScrobble(last: t0, now: t0.addingTimeInterval(2.9)))
    expect("tap exactly 3s after is allowed", shouldAllowScrobble(last: t0, now: t0.addingTimeInterval(3)))
    expect("tap 5s after is allowed", shouldAllowScrobble(last: t0, now: t0.addingTimeInterval(5)))
}
