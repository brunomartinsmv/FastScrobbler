import Foundation

func runScrobbleEngineTests() {
    // ─── Scrobble threshold ───────────────────────────────────────────────────────
    // Replicates maybeScrobble threshold logic from ScrobbleEngine.swift.
    // Threshold options: [0.10, 0.25, 0.50, 0.75]. Default index: 2 (50%).
    // Normally tracks must be >= 30s, but repeat-enabled mode allows shorter looped tracks too.
    // Scrobble when accumulatedPlaySeconds >= duration * fraction.

    section("Engine · Scrobble threshold calculation")

    let thresholdOptions: [Double] = [0.10, 0.25, 0.50, 0.75]

    func shouldScrobble(played: Double, duration: Double, thresholdIndex: Int, allowRepeatScrobbles: Bool = false) -> Bool {
        guard duration >= 30 || allowRepeatScrobbles else { return false }
        let idx = min(max(thresholdIndex, 0), thresholdOptions.count - 1)
        let threshold = duration * thresholdOptions[idx]
        return played >= threshold
    }

    enum SimPlaybackState {
        case playing
        case paused
        case stopped
    }

    func shouldAutoScrobble(playbackState: SimPlaybackState, played: Double, duration: Double, thresholdIndex: Int, allowRepeatScrobbles: Bool = false) -> Bool {
        guard playbackState == .playing else { return false }
        return shouldScrobble(played: played, duration: duration, thresholdIndex: thresholdIndex, allowRepeatScrobbles: allowRepeatScrobbles)
    }

    func rawPlaybackTimeCrossedThreshold(_ rawPlaybackTime: Double, duration: Double, threshold: Double, elapsedSinceStart: Double) -> Bool {
        rawPlaybackTime >= threshold &&
            rawPlaybackTime <= duration + 2 &&
            elapsedSinceStart >= threshold - 2
    }

    func effectivePlayedAfterRawFallback(accumulated: Double, rawPlaybackTime: Double, duration: Double, thresholdIndex: Int, elapsedSinceStart: Double) -> Double {
        let idx = min(max(thresholdIndex, 0), thresholdOptions.count - 1)
        let threshold = duration * thresholdOptions[idx]
        guard accumulated < threshold else { return accumulated }
        if rawPlaybackTimeCrossedThreshold(rawPlaybackTime, duration: duration, threshold: threshold, elapsedSinceStart: elapsedSinceStart) {
            return threshold
        }
        return accumulated
    }

    func shouldDetectLoopRestart(lastPlaybackTime: Double, playbackTime: Double, duration: Double, allowRepeatScrobbles: Bool, resumeWindowActive: Bool = false, gapSeconds: Double? = 1) -> Bool {
        guard allowRepeatScrobbles else { return false }
        guard !resumeWindowActive else { return false }
        guard gapSeconds.map({ $0 <= 12 }) ?? true else { return false }
        guard lastPlaybackTime > playbackTime else { return false }

        let restartProgressThreshold: Double = {
            guard duration > 0 else { return 15 }
            return max(3, min(15, duration * 0.6))
        }()
        let restartResetThreshold: Double = {
            guard duration > 0 else { return 5 }
            return max(2, min(5, duration * 0.35))
        }()
        let dropThreshold: Double = {
            guard duration > 0 else { return 30 }
            return max(2, min(10, duration * 0.5))
        }()

        guard lastPlaybackTime >= restartProgressThreshold else { return false }
        guard playbackTime <= restartResetThreshold else { return false }
        return (lastPlaybackTime - playbackTime) >= dropThreshold
    }

    func simulateLoopedScrobbleTimestamps(loopCount: Int, duration: Double, thresholdIndex: Int, allowRepeatScrobbles: Bool, startedAt: Int = 10_000) -> [Int] {
        guard loopCount > 0 else { return [] }
        var timestamps: [Int] = []
        var currentStart = startedAt

        for loopIndex in 0..<loopCount {
            guard shouldScrobble(
                played: duration,
                duration: duration,
                thresholdIndex: thresholdIndex,
                allowRepeatScrobbles: allowRepeatScrobbles
            ) else {
                break
            }
            timestamps.append(currentStart)

            guard loopIndex < loopCount - 1 else { break }
            guard shouldDetectLoopRestart(
                lastPlaybackTime: max(duration - 0.25, duration * 0.9),
                playbackTime: min(1.0, max(0.25, duration * 0.1)),
                duration: duration,
                allowRepeatScrobbles: allowRepeatScrobbles
            ) else {
                break
            }
            currentStart += max(Int(duration.rounded(.down)), 1)
        }

        return timestamps
    }

    func accumulatePlaySeconds(current: Double, previousPlaybackTime: Double, playbackTime: Double, wallDelta: Double) -> Double {
        guard wallDelta > 0 else { return current }
        let playbackDelta = playbackTime - previousPlaybackTime
        guard playbackDelta > 0 else { return current }
        return current + min(playbackDelta, wallDelta)
    }

    func renderInactiveStatus(artist: String, title: String, playbackState: SimPlaybackState, hasSentNowPlaying: Bool = false, hasScrobbled: Bool = false, hasLoved: Bool = false) -> String {
        var bits = ["\(artist) - \(title)"]
        bits.append(playbackState == .paused ? "paused" : "Idle")
        if hasSentNowPlaying { bits.append("now playing sent") }
        if hasScrobbled { bits.append("scrobbled") }
        if hasLoved { bits.append("loved") }
        return bits.joined(separator: " | ")
    }

    // 10% threshold (index 0): 60s song → need 6s
    expect("10% threshold: 6s of 60s triggers",  shouldScrobble(played: 6, duration: 60, thresholdIndex: 0))
    expect("10% threshold: 5s of 60s blocked",   !shouldScrobble(played: 5, duration: 60, thresholdIndex: 0))

    // 50% threshold (index 2): 60s song → need 30s
    expect("50% threshold: 30s of 60s triggers", shouldScrobble(played: 30, duration: 60, thresholdIndex: 2))
    expect("50% threshold: 29s of 60s blocked",  !shouldScrobble(played: 29, duration: 60, thresholdIndex: 2))

    // 75% threshold (index 3): 60s song → need 45s
    expect("75% threshold: 45s of 60s triggers", shouldScrobble(played: 45, duration: 60, thresholdIndex: 3))
    expect("75% threshold: 44s of 60s blocked",  !shouldScrobble(played: 44, duration: 60, thresholdIndex: 3))

    // Short tracks (<30s) never scrobble
    expect("29s track never scrobbles",          !shouldScrobble(played: 29, duration: 29, thresholdIndex: 0))
    expect("30s track can scrobble",             shouldScrobble(played: 3, duration: 30, thresholdIndex: 0))
    expect("short tracks can scrobble in repeat-enabled mode", shouldScrobble(played: 12, duration: 12, thresholdIndex: 2, allowRepeatScrobbles: true))

    // Index clamping
    expect("index -1 clamped to 0 (10%)",        shouldScrobble(played: 6, duration: 60, thresholdIndex: -1))
    expect("index 99 clamped to 3 (75%)",        !shouldScrobble(played: 44, duration: 60, thresholdIndex: 99))

    section("Engine · Raw playback-time threshold fallback")

    let fallbackDuration = 120.0
    let fallbackThreshold = fallbackDuration * thresholdOptions[2]

    expect("raw fallback triggers at exact threshold",
           rawPlaybackTimeCrossedThreshold(fallbackThreshold, duration: fallbackDuration, threshold: fallbackThreshold, elapsedSinceStart: fallbackThreshold))
    expect("raw fallback triggers after threshold",
           rawPlaybackTimeCrossedThreshold(75, duration: fallbackDuration, threshold: fallbackThreshold, elapsedSinceStart: 75))
    expect("raw fallback is blocked below threshold",
           !rawPlaybackTimeCrossedThreshold(59.9, duration: fallbackDuration, threshold: fallbackThreshold, elapsedSinceStart: 59.9))
    expect("raw fallback tolerates small end-of-track overshoot",
           rawPlaybackTimeCrossedThreshold(122, duration: fallbackDuration, threshold: fallbackThreshold, elapsedSinceStart: 122))
    expect("raw fallback rejects impossible playback positions",
           !rawPlaybackTimeCrossedThreshold(123, duration: fallbackDuration, threshold: fallbackThreshold, elapsedSinceStart: 123))
    expect("raw fallback is blocked when raw playback only crossed threshold by seeking",
           !rawPlaybackTimeCrossedThreshold(75, duration: fallbackDuration, threshold: fallbackThreshold, elapsedSinceStart: 5))
    expect("raw fallback allows small wall-clock timing tolerance",
           rawPlaybackTimeCrossedThreshold(60, duration: fallbackDuration, threshold: fallbackThreshold, elapsedSinceStart: 58))

    let laggedAccumulated = effectivePlayedAfterRawFallback(
        accumulated: 48,
        rawPlaybackTime: 61,
        duration: fallbackDuration,
        thresholdIndex: 2,
        elapsedSinceStart: 61
    )
    expect("lagged accumulated time is promoted to threshold after raw playback crosses it",
           laggedAccumulated == fallbackThreshold,
           detail: "got \(laggedAccumulated)")
    expect("promoted fallback time allows auto-scrobble while playing",
           shouldAutoScrobble(playbackState: .playing, played: laggedAccumulated, duration: fallbackDuration, thresholdIndex: 2))

    let belowThresholdAccumulated = effectivePlayedAfterRawFallback(
        accumulated: 48,
        rawPlaybackTime: 59,
        duration: fallbackDuration,
        thresholdIndex: 2,
        elapsedSinceStart: 59
    )
    expect("fallback does not promote before raw playback crosses threshold",
           belowThresholdAccumulated == 48,
           detail: "got \(belowThresholdAccumulated)")

    let seekedAccumulated = effectivePlayedAfterRawFallback(
        accumulated: 5,
        rawPlaybackTime: 75,
        duration: fallbackDuration,
        thresholdIndex: 2,
        elapsedSinceStart: 5
    )
    expect("fallback does not promote a quick seek past the threshold",
           seekedAccumulated == 5,
           detail: "got \(seekedAccumulated)")

    section("Engine · Paused playback suspends auto-scrobble checks")

    expect("paused track above threshold does not auto-scrobble", !shouldAutoScrobble(playbackState: .paused, played: 30, duration: 60, thresholdIndex: 2))
    expect("stopped track above threshold does not auto-scrobble", !shouldAutoScrobble(playbackState: .stopped, played: 30, duration: 60, thresholdIndex: 2))

    let pausedAccumulated = accumulatePlaySeconds(current: 25, previousPlaybackTime: 25, playbackTime: 25, wallDelta: 5)
    expect("paused tick preserves accumulated play time", pausedAccumulated == 25, detail: "got \(pausedAccumulated)")

    let resumedAccumulated = accumulatePlaySeconds(current: pausedAccumulated, previousPlaybackTime: 25, playbackTime: 30, wallDelta: 5)
    expect("resume tick adds newly played seconds", resumedAccumulated == 30, detail: "got \(resumedAccumulated)")
    expect("resumed playback can scrobble once threshold is met", shouldAutoScrobble(playbackState: .playing, played: resumedAccumulated, duration: 60, thresholdIndex: 2))
    expect("repeat-enabled short track can auto-scrobble once threshold is met", shouldAutoScrobble(playbackState: .playing, played: 12, duration: 12, thresholdIndex: 2, allowRepeatScrobbles: true))

    let pausedStatus = renderInactiveStatus(artist: "Depeche Mode", title: "Waiting for the Night", playbackState: .paused, hasSentNowPlaying: true)
    expect("paused status renders paused marker", pausedStatus.contains("paused"), detail: "got '\(pausedStatus)'")
    expect("paused status omits countdown text", !pausedStatus.contains("to scrobble"), detail: "got '\(pausedStatus)'")

    section("Engine · Looped track restart detection")

    expect("short looped tracks trigger restart detection in repeat-enabled mode",
           shouldDetectLoopRestart(lastPlaybackTime: 10, playbackTime: 1, duration: 12, allowRepeatScrobbles: true))
    expect("restart detection stays off when repeat scrobbling is disabled",
           !shouldDetectLoopRestart(lastPlaybackTime: 10, playbackTime: 1, duration: 12, allowRepeatScrobbles: false))

    let loopedTimestamps = simulateLoopedScrobbleTimestamps(loopCount: 20, duration: 12, thresholdIndex: 2, allowRepeatScrobbles: true)
    expectEqual("20-loop run produces 20 live scrobbles in repeat-enabled mode", loopedTimestamps.count, 20)
    expectEqual("20-loop run produces distinct timestamps", Set(loopedTimestamps).count, 20)
}
