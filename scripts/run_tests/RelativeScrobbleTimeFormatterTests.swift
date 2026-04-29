import Foundation

func runRelativeScrobbleTimeFormatterTests() {
    section("Relative scrobble time formatter")

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func formatted(secondsAgo: TimeInterval) -> String {
        RelativeScrobbleTimeFormatter.string(from: now.addingTimeInterval(-secondsAgo), to: now)
    }

    expectEqual("zero minutes", formatted(secondsAgo: 0), "0m ago")
    expectEqual("future dates clamp to zero minutes", RelativeScrobbleTimeFormatter.string(from: now.addingTimeInterval(60), to: now), "0m ago")
    expectEqual("fifty-nine minutes", formatted(secondsAgo: 59 * 60), "59m ago")
    expectEqual("one hour", formatted(secondsAgo: 60 * 60), "1h ago")
    expectEqual("one hour one minute", formatted(secondsAgo: 61 * 60), "1h 1m ago")
    expectEqual("twenty-three hours fifty-nine minutes", formatted(secondsAgo: (23 * 60 + 59) * 60), "23h 59m ago")
    expectEqual("one day", formatted(secondsAgo: 24 * 60 * 60), "1d ago")
    expectEqual("one day one hour", formatted(secondsAgo: 25 * 60 * 60), "1d 1h ago")
    expectEqual("sixteen days nineteen hours", formatted(secondsAgo: (16 * 24 + 19) * 60 * 60), "16d 19h ago")
}
