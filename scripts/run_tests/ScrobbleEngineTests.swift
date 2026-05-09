import Foundation

func runScrobbleEngineTests() {
    // ─── Scrobble threshold ───────────────────────────────────────────────────────
    // Replicates maybeScrobble threshold logic from ScrobbleEngine.swift.
    // Threshold options: iOS [0.10, 0.25, 0.50, 0.75], macOS adds 0.90. Default index: 2 (50%).
    // Normally tracks must be >= 30s, but repeat-enabled mode allows shorter looped tracks too.
    // Scrobble when accumulatedPlaySeconds >= duration * fraction.

    section("Engine · Scrobble threshold calculation")

    let thresholdOptions: [Double] = [0.10, 0.25, 0.50, 0.75, 0.90]

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

    enum SimScrobbleAttemptOutcome: Equatable {
        case belowThreshold
        case inactivePlayback
        case duplicate
        case retryableFailure(queued: Bool)
        case nonRetryableFailure
        case submitted
    }

    func shouldAutoScrobble(playbackState: SimPlaybackState, played: Double, duration: Double, thresholdIndex: Int, allowRepeatScrobbles: Bool = false) -> Bool {
        guard playbackState == .playing else { return false }
        return shouldScrobble(played: played, duration: duration, thresholdIndex: thresholdIndex, allowRepeatScrobbles: allowRepeatScrobbles)
    }

    func autoScrobbleAttemptOutcome(
        playbackState: SimPlaybackState,
        played: Double,
        duration: Double,
        thresholdIndex: Int,
        isDuplicate: Bool = false,
        simulatedErrorIsRetryable: Bool? = nil,
        alreadyQueued: Bool = false
    ) -> SimScrobbleAttemptOutcome {
        guard playbackState == .playing else { return .inactivePlayback }
        guard shouldScrobble(played: played, duration: duration, thresholdIndex: thresholdIndex) else { return .belowThreshold }
        if isDuplicate { return .duplicate }
        if let retryable = simulatedErrorIsRetryable {
            return retryable ? .retryableFailure(queued: !alreadyQueued) : .nonRetryableFailure
        }
        return .submitted
    }

    func rawPlaybackTimeCrossedThreshold(_ rawPlaybackTime: Double, duration: Double, threshold: Double) -> Bool {
        rawPlaybackTime >= threshold &&
            rawPlaybackTime <= duration + 2
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

    func accumulateFallbackPlaySeconds(
        current: Double,
        previousPlaybackTime: Double,
        playbackTime: Double,
        wallDelta: Double,
        usesFallbackDuration: Bool,
        isPlaying: Bool,
        duration: Double
    ) -> Double {
        guard wallDelta > 0 else { return current }
        let playbackDelta = playbackTime - previousPlaybackTime
        var played = current
        if playbackDelta > 0 {
            played += min(playbackDelta, wallDelta)
        } else if usesFallbackDuration && isPlaying && playbackDelta <= 0 {
            played += wallDelta
        }
        if duration > 0 {
            played = min(played, duration)
        }
        return played
    }

    func displayPlayedSeconds(accumulated: Double, rawPlaybackTime: Double, duration: Double) -> Double {
        let raw = max(0, rawPlaybackTime)
        guard duration > 0 else { return raw }
        return min(raw, duration)
    }

    func nowPlayingCardPlayedSeconds(
        usesFallbackDuration: Bool,
        displayPlaybackSeconds: Double,
        effectivePlayedSeconds: Double,
        duration: Double
    ) -> Double {
        let selected = usesFallbackDuration ? effectivePlayedSeconds : displayPlaybackSeconds
        return min(max(0, selected), duration)
    }

    func thresholdQualifiedPlaybackSeconds(
        usesFallbackDuration: Bool,
        rawPlaybackTime: Double,
        effectivePlayedSeconds: Double
    ) -> Double {
        usesFallbackDuration ? effectivePlayedSeconds : max(0, rawPlaybackTime)
    }

    func renderInactiveStatus(artist: String, title: String, playbackState: SimPlaybackState, played: Double = 0, duration: Double = 0, thresholdIndex: Int = 2, hasSentNowPlaying: Bool = false, hasScrobbled: Bool = false, hasLoved: Bool = false, failureMessage: String? = nil) -> String {
        var bits = ["\(artist) - \(title)"]
        bits.append(playbackState == .paused ? "paused" : "Idle")
        if let failureMessage {
            bits.append(failureMessage)
        } else if !hasScrobbled, shouldScrobble(played: played, duration: duration, thresholdIndex: thresholdIndex) {
            bits.append("Ready to scrobble when playback resumes.")
        }
        if hasSentNowPlaying { bits.append("now playing sent") }
        if hasScrobbled { bits.append("scrobbled") }
        if hasLoved { bits.append("loved") }
        return bits.joined(separator: " | ")
    }

    func fallbackDurationStatusText(usesFallbackDuration: Bool) -> String? {
        guard usesFallbackDuration else { return nil }
        return "Could not retrieve track duration from Music app; using fallback duration of 3 minutes."
    }

    func autoStartTimestampIsReliable(
        hasObservedPlaybackProgress: Bool,
        hasObservedFallbackPlaybackProgress: Bool = false,
        pendingColdStartDedupeCheck: Bool,
        usesFallbackDuration: Bool = false
    ) -> Bool {
        if pendingColdStartDedupeCheck {
            return usesFallbackDuration && hasObservedFallbackPlaybackProgress
        }
        return hasObservedPlaybackProgress || (usesFallbackDuration && hasObservedFallbackPlaybackProgress)
    }

    func shouldApplyThrottle(lastAttemptSecondsAgo: Double?) -> Bool {
        guard let lastAttemptSecondsAgo else { return false }
        return lastAttemptSecondsAgo < 15
    }

    func shouldDeferColdStartDedupe(playbackTime: Double, gapSeconds: Double?) -> Bool {
        playbackTime <= 0 || gapSeconds == nil || (gapSeconds ?? 0) > 12
    }

    func normalizedAutoPlaybackState(
        rawPlaybackState: SimPlaybackState,
        previousPlaybackTime: Double?,
        playbackTime: Double,
        wallDelta: Double?
    ) -> SimPlaybackState {
        guard rawPlaybackState != .playing else { return .playing }
        guard let previousPlaybackTime, let wallDelta else { return rawPlaybackState }
        let playbackDelta = playbackTime - previousPlaybackTime
        guard wallDelta > 0, wallDelta <= 3 else { return rawPlaybackState }
        guard playbackDelta >= 0.75, playbackDelta <= wallDelta + 0.75 else { return rawPlaybackState }
        return .playing
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

    // 90% threshold (index 4 on macOS): 60s song -> need 54s
    expect("90% threshold: 54s of 60s triggers", shouldScrobble(played: 54, duration: 60, thresholdIndex: 4))
    expect("90% threshold: 53s of 60s blocked",  !shouldScrobble(played: 53, duration: 60, thresholdIndex: 4))

    // Fallback duration: 180s
    expect("fallback 180s at 10% threshold triggers at 18s", shouldScrobble(played: 18, duration: 180, thresholdIndex: 0))
    expect("fallback 180s at default 50% threshold triggers at 90s", shouldScrobble(played: 90, duration: 180, thresholdIndex: 2))
    expect("fallback 180s at 75% threshold triggers at 135s", shouldScrobble(played: 135, duration: 180, thresholdIndex: 3))
    expect("fallback 180s at 90% threshold triggers at 162s", shouldScrobble(played: 162, duration: 180, thresholdIndex: 4))

    // Short tracks (<30s) never scrobble
    expect("29s track never scrobbles",          !shouldScrobble(played: 29, duration: 29, thresholdIndex: 0))
    expect("30s track can scrobble",             shouldScrobble(played: 3, duration: 30, thresholdIndex: 0))
    expect("short tracks can scrobble in repeat-enabled mode", shouldScrobble(played: 12, duration: 12, thresholdIndex: 2, allowRepeatScrobbles: true))

    // Index clamping
    expect("index -1 clamped to 0 (10%)",        shouldScrobble(played: 6, duration: 60, thresholdIndex: -1))
    expect("index 99 clamped to 4 (90%)",        !shouldScrobble(played: 53, duration: 60, thresholdIndex: 99))

    section("Engine · Raw playback-time threshold position")

    let fallbackDuration = 120.0
    let fallbackThreshold = fallbackDuration * thresholdOptions[2]

    expect("raw playback triggers at exact threshold",
           rawPlaybackTimeCrossedThreshold(fallbackThreshold, duration: fallbackDuration, threshold: fallbackThreshold))
    expect("raw playback triggers after threshold",
           rawPlaybackTimeCrossedThreshold(75, duration: fallbackDuration, threshold: fallbackThreshold))
    expect("raw playback is blocked below threshold",
           !rawPlaybackTimeCrossedThreshold(59.9, duration: fallbackDuration, threshold: fallbackThreshold))
    expect("raw playback tolerates small end-of-track overshoot",
           rawPlaybackTimeCrossedThreshold(122, duration: fallbackDuration, threshold: fallbackThreshold))
    expect("raw playback rejects impossible playback positions",
           !rawPlaybackTimeCrossedThreshold(123, duration: fallbackDuration, threshold: fallbackThreshold))
    expect("forward seek past threshold qualifies immediately",
           rawPlaybackTimeCrossedThreshold(75, duration: fallbackDuration, threshold: fallbackThreshold))
    expect("backward seek below threshold is no longer qualified",
           !rawPlaybackTimeCrossedThreshold(5, duration: fallbackDuration, threshold: fallbackThreshold))

    section("Engine · Fallback self-counted played time")

    let fallbackSelfCounted = accumulateFallbackPlaySeconds(
        current: 0,
        previousPlaybackTime: 0,
        playbackTime: 0,
        wallDelta: 5,
        usesFallbackDuration: true,
        isPlaying: true,
        duration: 180
    )
    expect("fallback session self-counts wall time when playback time is stuck at zero",
           fallbackSelfCounted == 5,
           detail: "got \(fallbackSelfCounted)")
    expect("fallback self-counted time can satisfy the 10% threshold",
           shouldScrobble(played: 18, duration: 180, thresholdIndex: 0))
    expect("fallback self-counted time can satisfy the 25% threshold",
           shouldScrobble(played: 45, duration: 180, thresholdIndex: 1))
    expect("fallback self-counted time can satisfy the 50% threshold",
           shouldScrobble(played: 90, duration: 180, thresholdIndex: 2))
    expect("fallback self-counted time can satisfy the 75% threshold",
           shouldScrobble(played: 135, duration: 180, thresholdIndex: 3))
    expect("fallback self-counted time can satisfy the 90% threshold",
           shouldScrobble(played: 162, duration: 180, thresholdIndex: 4))

    let fallbackPaused = accumulateFallbackPlaySeconds(
        current: 5,
        previousPlaybackTime: 0,
        playbackTime: 0,
        wallDelta: 5,
        usesFallbackDuration: true,
        isPlaying: false,
        duration: 180
    )
    expect("paused fallback session does not self-count wall time",
           fallbackPaused == 5,
           detail: "got \(fallbackPaused)")

    let fallbackResumed = accumulateFallbackPlaySeconds(
        current: fallbackPaused,
        previousPlaybackTime: 0,
        playbackTime: 0,
        wallDelta: 5,
        usesFallbackDuration: true,
        isPlaying: true,
        duration: 180
    )
    expect("resumed fallback session resumes self-counting wall time",
           fallbackResumed == 10,
           detail: "got \(fallbackResumed)")

    let fallbackClamped = accumulateFallbackPlaySeconds(
        current: 178,
        previousPlaybackTime: 0,
        playbackTime: 0,
        wallDelta: 5,
        usesFallbackDuration: true,
        isPlaying: true,
        duration: 180
    )
    expect("fallback self-counting is clamped to the fallback duration",
           fallbackClamped == 180,
           detail: "got \(fallbackClamped)")

    expectEqual("displayed played time follows raw zero even if accumulated is higher",
                displayPlayedSeconds(accumulated: 42, rawPlaybackTime: 0, duration: 180),
                0)
    expectEqual("displayed played time follows raw playback after a seek",
                displayPlayedSeconds(accumulated: 42, rawPlaybackTime: 50, duration: 180),
                50)
    expectEqual("displayed played time clamps to duration",
                displayPlayedSeconds(accumulated: 42, rawPlaybackTime: 190, duration: 180),
                180)
    expectEqual("fallback-duration now playing card uses effective played seconds",
                nowPlayingCardPlayedSeconds(
                    usesFallbackDuration: true,
                    displayPlaybackSeconds: 12,
                    effectivePlayedSeconds: 42,
                    duration: 180
                ),
                42)
    expectEqual("normal-duration now playing card uses display playback seconds",
                nowPlayingCardPlayedSeconds(
                    usesFallbackDuration: false,
                    displayPlaybackSeconds: 12,
                    effectivePlayedSeconds: 42,
                    duration: 180
                ),
                12)
    expectEqual("fallback-duration now playing card clamps selected played time to duration",
                nowPlayingCardPlayedSeconds(
                    usesFallbackDuration: true,
                    displayPlaybackSeconds: 12,
                    effectivePlayedSeconds: 240,
                    duration: 180
                ),
                180)
    expect("fallback-duration now playing card prefers effective played time over display playback time",
           nowPlayingCardPlayedSeconds(
                usesFallbackDuration: true,
                displayPlaybackSeconds: 12,
                effectivePlayedSeconds: 42,
                duration: 180
           ) > nowPlayingCardPlayedSeconds(
                usesFallbackDuration: false,
                displayPlaybackSeconds: 12,
                effectivePlayedSeconds: 42,
                duration: 180
           ))
    expectEqual("fallback-duration auto-scrobble threshold uses effective played seconds",
                thresholdQualifiedPlaybackSeconds(
                    usesFallbackDuration: true,
                    rawPlaybackTime: 12,
                    effectivePlayedSeconds: 42
                ),
                42)
    expectEqual("normal-duration auto-scrobble threshold uses raw playback time",
                thresholdQualifiedPlaybackSeconds(
                    usesFallbackDuration: false,
                    rawPlaybackTime: 12,
                    effectivePlayedSeconds: 42
                ),
                12)
    expect("fallback-duration track can qualify threshold even when raw playback time is stuck low",
           rawPlaybackTimeCrossedThreshold(
                thresholdQualifiedPlaybackSeconds(
                    usesFallbackDuration: true,
                    rawPlaybackTime: 12,
                    effectivePlayedSeconds: 28
                ),
                duration: 180,
                threshold: 18
           ))
    expect("normal-duration track does not qualify threshold when raw playback time is below threshold",
           !rawPlaybackTimeCrossedThreshold(
                thresholdQualifiedPlaybackSeconds(
                    usesFallbackDuration: false,
                    rawPlaybackTime: 12,
                    effectivePlayedSeconds: 28
                ),
                duration: 180,
                threshold: 18
           ))
    expect("fallback session below threshold is not scrobble-eligible early",
           !shouldScrobble(played: 17, duration: 180, thresholdIndex: 0))

    section("Engine · Paused playback suspends auto-scrobble checks")

    expect("paused track above threshold does not auto-scrobble", !shouldAutoScrobble(playbackState: .paused, played: 30, duration: 60, thresholdIndex: 2))
    expect("stopped track above threshold does not auto-scrobble", !shouldAutoScrobble(playbackState: .stopped, played: 30, duration: 60, thresholdIndex: 2))
    expectEqual("paused track above threshold reports inactive attempt outcome",
                autoScrobbleAttemptOutcome(playbackState: .paused, played: 30, duration: 60, thresholdIndex: 2),
                .inactivePlayback)

    section("Engine · Fallback duration status")

    expectEqual(
        "fallback duration shows informational status message",
        fallbackDurationStatusText(usesFallbackDuration: true),
        "Could not retrieve track duration from Music app; using fallback duration of 3 minutes."
    )
    expectEqual(
        "real duration does not show fallback status message",
        fallbackDurationStatusText(usesFallbackDuration: false),
        nil
    )

    let pausedAccumulated = accumulatePlaySeconds(current: 25, previousPlaybackTime: 25, playbackTime: 25, wallDelta: 5)
    expect("paused tick preserves accumulated play time", pausedAccumulated == 25, detail: "got \(pausedAccumulated)")

    let resumedAccumulated = accumulatePlaySeconds(current: pausedAccumulated, previousPlaybackTime: 25, playbackTime: 30, wallDelta: 5)
    expect("resume tick adds newly played seconds", resumedAccumulated == 30, detail: "got \(resumedAccumulated)")
    expect("resumed playback can scrobble once threshold is met", shouldAutoScrobble(playbackState: .playing, played: resumedAccumulated, duration: 60, thresholdIndex: 2))
    expectEqual("resumed playback after threshold is immediately submitted",
                autoScrobbleAttemptOutcome(playbackState: .playing, played: 30, duration: 60, thresholdIndex: 2),
                .submitted)
    expect("repeat-enabled short track can auto-scrobble once threshold is met", shouldAutoScrobble(playbackState: .playing, played: 12, duration: 12, thresholdIndex: 2, allowRepeatScrobbles: true))

    let pausedStatus = renderInactiveStatus(artist: "Depeche Mode", title: "Waiting for the Night", playbackState: .paused, hasSentNowPlaying: true)
    expect("paused status renders paused marker", pausedStatus.contains("paused"), detail: "got '\(pausedStatus)'")
    expect("paused status omits countdown text", !pausedStatus.contains("to scrobble"), detail: "got '\(pausedStatus)'")

    let thresholdReadyStatus = renderInactiveStatus(
        artist: "Depeche Mode",
        title: "Waiting for the Night",
        playbackState: .paused,
        played: 30,
        duration: 60,
        thresholdIndex: 2,
        hasSentNowPlaying: true
    )
    expect("paused threshold-qualified status says it is ready on resume",
           thresholdReadyStatus.contains("Ready to scrobble when playback resumes."),
           detail: "got '\(thresholdReadyStatus)'")

    section("Engine · Auto timestamp trust and mac playback-state normalization")

    expect("cold start dedupe is deferred when playback time starts at zero",
           shouldDeferColdStartDedupe(playbackTime: 0, gapSeconds: 1))
    expect("cold start dedupe is deferred after a long execution gap",
           shouldDeferColdStartDedupe(playbackTime: 42, gapSeconds: 20))
    expect("normal track changes keep immediate dedupe when timing is credible",
           !shouldDeferColdStartDedupe(playbackTime: 4, gapSeconds: 1))

    expect("auto timestamp is not trusted before playback progression is observed",
           !autoStartTimestampIsReliable(hasObservedPlaybackProgress: false, pendingColdStartDedupeCheck: true))
    expect("timestamp trust remains a dedupe/correction signal rather than a submission blocker",
           !autoStartTimestampIsReliable(hasObservedPlaybackProgress: false, pendingColdStartDedupeCheck: true))
    expect("fallback session becomes timestamp-reliable after fallback wall-clock progress",
           autoStartTimestampIsReliable(
                hasObservedPlaybackProgress: false,
                hasObservedFallbackPlaybackProgress: true,
                pendingColdStartDedupeCheck: true,
                usesFallbackDuration: true
           ))
    expect("paused fallback session without fallback progress is not timestamp-reliable",
           !autoStartTimestampIsReliable(
                hasObservedPlaybackProgress: false,
                hasObservedFallbackPlaybackProgress: false,
                pendingColdStartDedupeCheck: true,
                usesFallbackDuration: true
           ))
    expect("auto timestamp becomes trusted after playback progression clears the cold-start guard",
           autoStartTimestampIsReliable(hasObservedPlaybackProgress: true, pendingColdStartDedupeCheck: false))
    expect("fallback session remains timestamp-reliable after cold-start guard clears",
           autoStartTimestampIsReliable(
                hasObservedPlaybackProgress: false,
                hasObservedFallbackPlaybackProgress: true,
                pendingColdStartDedupeCheck: false,
                usesFallbackDuration: true
           ))

    expectEqual("mac stale paused state is normalized to playing when position clearly advances",
                normalizedAutoPlaybackState(rawPlaybackState: .paused, previousPlaybackTime: 12, playbackTime: 13.2, wallDelta: 1.0),
                .playing)
    expectEqual("normalization stays off for truly paused playback",
                normalizedAutoPlaybackState(rawPlaybackState: .paused, previousPlaybackTime: 12, playbackTime: 12, wallDelta: 1.0),
                .paused)
    expectEqual("normalization stays off for implausibly large jumps",
                normalizedAutoPlaybackState(rawPlaybackState: .paused, previousPlaybackTime: 12, playbackTime: 18, wallDelta: 1.0),
                .paused)

    section("Engine · Auto-scrobble attempt outcomes")

    expectEqual("retryable failure queues once",
                autoScrobbleAttemptOutcome(playbackState: .playing, played: 30, duration: 60, thresholdIndex: 2, simulatedErrorIsRetryable: true),
                .retryableFailure(queued: true))
    expectEqual("retryable duplicate failure does not enqueue again",
                autoScrobbleAttemptOutcome(playbackState: .playing, played: 30, duration: 60, thresholdIndex: 2, simulatedErrorIsRetryable: true, alreadyQueued: true),
                .retryableFailure(queued: false))
    expectEqual("non-retryable failure remains visible",
                autoScrobbleAttemptOutcome(playbackState: .playing, played: 30, duration: 60, thresholdIndex: 2, simulatedErrorIsRetryable: false),
                .nonRetryableFailure)
    expectEqual("duplicate match reports duplicate outcome",
                autoScrobbleAttemptOutcome(playbackState: .playing, played: 30, duration: 60, thresholdIndex: 2, isDuplicate: true),
                .duplicate)
    expect("local timestamp-validation preflight does not trigger throttle when no real attempt was recorded",
           !shouldApplyThrottle(lastAttemptSecondsAgo: nil))
    expect("real outbound attempt triggers throttle inside 15 seconds",
           shouldApplyThrottle(lastAttemptSecondsAgo: 5))
    expect("retryable failure still uses the same attempt throttle window",
           shouldApplyThrottle(lastAttemptSecondsAgo: 5))
    expect("throttle window expires after 15 seconds",
           !shouldApplyThrottle(lastAttemptSecondsAgo: 15))

    let nonRetryableStatus = renderInactiveStatus(
        artist: "Depeche Mode",
        title: "Waiting for the Night",
        playbackState: .paused,
        failureMessage: "Last.fm ignored this scrobble."
    )
    expect("non-retryable failure status includes Last.fm message",
           nonRetryableStatus.contains("Last.fm ignored this scrobble."),
           detail: "got '\(nonRetryableStatus)'")

    section("Engine · Looped track restart detection")

    expect("short looped tracks trigger restart detection in repeat-enabled mode",
           shouldDetectLoopRestart(lastPlaybackTime: 10, playbackTime: 1, duration: 12, allowRepeatScrobbles: true))
    expect("restart detection stays off when repeat scrobbling is disabled",
           !shouldDetectLoopRestart(lastPlaybackTime: 10, playbackTime: 1, duration: 12, allowRepeatScrobbles: false))

    let loopedTimestamps = simulateLoopedScrobbleTimestamps(loopCount: 20, duration: 12, thresholdIndex: 2, allowRepeatScrobbles: true)
    expectEqual("20-loop run produces 20 live scrobbles in repeat-enabled mode", loopedTimestamps.count, 20)
    expectEqual("20-loop run produces distinct timestamps", Set(loopedTimestamps).count, 20)
}
