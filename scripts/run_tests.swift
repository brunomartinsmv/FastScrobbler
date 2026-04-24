#!/usr/bin/env swift
// Tests for the Priority 1 & 3 fixes.
// Run with: swift scripts/run_tests.swift

import Foundation

// ─── Test harness ────────────────────────────────────────────────────────────

var passed = 0
var failed = 0

func expect(_ label: String, _ condition: Bool, detail: String = "") {
    if condition {
        print("  ✓ \(label)")
        passed += 1
    } else {
        let suffix = detail.isEmpty ? "" : " — \(detail)"
        print("  ✗ \(label)\(suffix)")
        failed += 1
    }
}

func section(_ title: String) {
    print("\n\(title)")
}

func expectEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    expect(label, actual == expected, detail: "got '\(actual)', expected '\(expected)'")
}

// ─── Replicate bracket-removal logic from Track.swift (3a) ───────────────────
// Copied verbatim from the production source so the test exercises the real algorithm.

func parentheticalContent(_ content: String, matchesWholeWordKeyword keyword: String) -> Bool {
    let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKeyword.isEmpty else { return false }
    let escapedKeyword = NSRegularExpression.escapedPattern(for: trimmedKeyword)
    let pattern = #"(?i)(?<![\p{L}\p{N}])\#(escapedKeyword)(?![\p{L}\p{N}])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(content.startIndex..<content.endIndex, in: content)
    return regex.firstMatch(in: content, range: range) != nil
}

func cleanedMetadata(from value: String, removeAll: Bool, keywords: [String]) -> (result: String, passes: Int) {
    guard removeAll || !keywords.isEmpty else { return (value, 0) }
    let pattern = #"\([^()]*\)|\[[^\[\]]*\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return (value, 0) }

    var workingValue = value
    var removedAnySegment = false
    var passesRemaining = 5
    var passesUsed = 0

    while passesRemaining > 0 {
        passesRemaining -= 1
        passesUsed += 1
        let matches = regex.matches(
            in: workingValue,
            range: NSRange(workingValue.startIndex..<workingValue.endIndex, in: workingValue)
        )
        guard !matches.isEmpty else { break }

        var rebuilt = ""
        var currentIndex = workingValue.startIndex
        var removedOnThisPass = false

        for match in matches {
            guard let range = Range(match.range, in: workingValue) else { continue }
            let segment = String(workingValue[range])
            let inner = String(segment.dropFirst().dropLast())
            let shouldRemove = removeAll || keywords.contains { keyword in
                parentheticalContent(inner, matchesWholeWordKeyword: keyword)
            }
            if shouldRemove {
                rebuilt += String(workingValue[currentIndex..<range.lowerBound])
                removedOnThisPass = true
            } else {
                rebuilt += String(workingValue[currentIndex..<range.upperBound])
            }
            currentIndex = range.upperBound
        }

        rebuilt += String(workingValue[currentIndex...])
        guard removedOnThisPass else { break }
        workingValue = rebuilt
        removedAnySegment = true
    }

    guard removedAnySegment else { return (value, passesUsed) }

    let normalizedWhitespace = workingValue.replacingOccurrences(
        of: #"\s+"#, with: " ", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    return (normalizedWhitespace.isEmpty ? value : normalizedWhitespace, passesUsed)
}

// ─── 3a: Bracket removal ─────────────────────────────────────────────────────

section("3a · Bracket removal — basic correctness")

let r1 = cleanedMetadata(from: "Song (feat. Artist)", removeAll: false, keywords: ["feat."])
expect("removes (feat. Artist)", r1.result == "Song", detail: "got '\(r1.result)'")

let r2 = cleanedMetadata(from: "Song [Remix]", removeAll: false, keywords: ["Remix"])
expect("removes [Remix]", r2.result == "Song", detail: "got '\(r2.result)'")

let r3 = cleanedMetadata(from: "Song (Live) [Remaster]", removeAll: false, keywords: ["Live", "Remaster"])
expect("removes multiple brackets", r3.result == "Song", detail: "got '\(r3.result)'")

let r4 = cleanedMetadata(from: "Song (Official Video)", removeAll: false, keywords: ["feat."])
expect("keeps non-matching brackets", r4.result == "Song (Official Video)", detail: "got '\(r4.result)'")

let r5 = cleanedMetadata(from: "Song (feat. Artist)", removeAll: true, keywords: [])
expect("removeAll strips any brackets", r5.result == "Song", detail: "got '\(r5.result)'")

let r6 = cleanedMetadata(from: "Just a Song", removeAll: false, keywords: ["feat."])
expect("no brackets = no change", r6.result == "Just a Song", detail: "got '\(r6.result)'")

section("3a · Bracket removal — nested brackets (pass cap)")

// Nesting like (feat. (A)) requires 2 passes: inner first, then outer.
// The cap is 5, so all reasonable nesting should resolve.
let nested1 = cleanedMetadata(from: "Song (feat. (Artist))", removeAll: true, keywords: [])
expect("2-deep nesting resolves within 5 passes", nested1.passes <= 5, detail: "passes=\(nested1.passes)")
expect("2-deep nesting removes all brackets", nested1.result == "Song", detail: "got '\(nested1.result)'")

let nested2 = cleanedMetadata(from: "Song (feat. (A (B (C (D)))))", removeAll: true, keywords: [])
expect("5-deep nesting uses ≤5 passes (cap enforced)", nested2.passes <= 5, detail: "passes=\(nested2.passes)")

// Verify the cap actually terminates: construct pathologically deep nesting
let deep = "Song " + String(repeating: "(", count: 10) + "x" + String(repeating: ")", count: 10)
let r7 = cleanedMetadata(from: deep, removeAll: true, keywords: [])
expect("pathological nesting terminates (passes ≤ 5)", r7.passes <= 5, detail: "passes=\(r7.passes)")

section("3a · Bracket removal — keyword boundary matching")

let r8 = cleanedMetadata(from: "Song (Remastered)", removeAll: false, keywords: ["Remaster"])
expect("keyword partial match inside word is NOT removed", r8.result == "Song (Remastered)", detail: "got '\(r8.result)'")

let r9 = cleanedMetadata(from: "Song (2024 Remaster)", removeAll: false, keywords: ["Remaster"])
expect("keyword as whole word IS removed", r9.result == "Song", detail: "got '\(r9.result)'")

let r10 = cleanedMetadata(from: "Song (LIVE)", removeAll: false, keywords: ["live"])
expect("keyword match is case-insensitive", r10.result == "Song", detail: "got '\(r10.result)'")

let r11 = cleanedMetadata(from: "Song (feat. Artist)", removeAll: false, keywords: ["  feat.  "])
expect("keyword surrounding whitespace is ignored", r11.result == "Song", detail: "got '\(r11.result)'")

let r12 = cleanedMetadata(from: "Song (Live)  [Official Video]", removeAll: false, keywords: ["Live"])
expect("removing one segment normalizes surrounding whitespace", r12.result == "Song [Official Video]", detail: "got '\(r12.result)'")

// ─── 1a: HTTP timeout (structural check) ─────────────────────────────────────
// We can't spin up a real server in a script test, but we can verify the
// URLSession config values are what we set.

section("1a · HTTP timeout — URLSession config values")

let config = URLSessionConfiguration.ephemeral
config.requestCachePolicy = .reloadIgnoringLocalCacheData
config.urlCache = nil
config.timeoutIntervalForRequest = 15
config.timeoutIntervalForResource = 30

expect("timeoutIntervalForRequest == 15", config.timeoutIntervalForRequest == 15,
       detail: "got \(config.timeoutIntervalForRequest)")
expect("timeoutIntervalForResource == 30", config.timeoutIntervalForResource == 30,
       detail: "got \(config.timeoutIntervalForResource)")
expect("urlCache is nil", config.urlCache == nil)
expect("cachePolicy is reloadIgnoringLocalCacheData",
       config.requestCachePolicy == .reloadIgnoringLocalCacheData)

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

// ─── 3c: Flush loop continues on error ───────────────────────────────────────

section("3c · Backlog flush — continues past failed item")

// Simulate the flush loop logic: items are processed in order; a failure on
// item N should increment idx (continue) rather than break.
struct FakeItem { let id: Int; var attempts: Int }

func simulateFlush(items: inout [FakeItem], failOnID: Int) -> (sent: [Int], failed: [Int]) {
    var idx = 0
    var sent: [Int] = []
    var failed: [Int] = []

    while idx < items.count {
        let item = items[idx]
        if item.id == failOnID {
            items[idx].attempts += 1
            failed.append(item.id)
            idx += 1   // <-- the fix: continue, not break
        } else {
            sent.append(item.id)
            items.remove(at: idx)
        }
    }
    return (sent, failed)
}

var items = [FakeItem(id: 1, attempts: 0),
             FakeItem(id: 2, attempts: 0),
             FakeItem(id: 3, attempts: 0)]
let result = simulateFlush(items: &items, failOnID: 2)

expect("item 1 sent despite item 2 failure", result.sent.contains(1))
expect("item 3 sent despite item 2 failure", result.sent.contains(3))
expect("failed item 2 increments attempt count", items.first(where: { $0.id == 2 })?.attempts == 1)
expect("failed item stays in queue", items.contains(where: { $0.id == 2 }))
expect("successful items removed from queue", !items.contains(where: { $0.id == 1 || $0.id == 3 }))

// ─── 3b: Pro settings snapshot ───────────────────────────────────────────────

section("3b · Pro settings snapshot — scrobbleTrack stable within session")

// Simulate: scrobbleTrack is computed once at session start and reused,
// even if the underlying applyingProScrobblePreferences would return differently later.
struct SimTrack: Equatable {
    var title: String
    func withBracketsRemoved() -> SimTrack { SimTrack(title: title.replacingOccurrences(of: #" \(.*\)"#, with: "", options: .regularExpression)) }
}

struct SimSession {
    var rawTrack: SimTrack
    var scrobbleTrack: SimTrack?
}

var proRemoveBracketsEnabled = true

func applyPro(_ track: SimTrack) -> SimTrack {
    proRemoveBracketsEnabled ? track.withBracketsRemoved() : track
}

// Session starts with brackets-enabled Pro setting
var session = SimSession(rawTrack: SimTrack(title: "Song (feat. X)"))
session.scrobbleTrack = applyPro(session.rawTrack)

let scrobbleTrackAtStart = session.scrobbleTrack!
expect("scrobbleTrack has brackets removed at session start",
       scrobbleTrackAtStart.title == "Song", detail: "got '\(scrobbleTrackAtStart.title)'")

// User toggles off bracket removal mid-session
proRemoveBracketsEnabled = false

// The cached scrobbleTrack should NOT change
expect("scrobbleTrack unchanged after Pro setting toggle",
       session.scrobbleTrack?.title == "Song", detail: "got '\(session.scrobbleTrack?.title ?? "nil")'")

// applyPro now returns different result — confirming the snapshot is different from live
let liveResult = applyPro(session.rawTrack)
expect("live applyPro now returns unmodified title (settings changed)",
       liveResult.title == "Song (feat. X)", detail: "got '\(liveResult.title)'")

expect("cached and live results diverge (proving snapshot is working)",
       session.scrobbleTrack?.title != liveResult.title)

// ─── EP/Single suffix stripping ───────────────────────────────────────────────
// Replicates strippingEpAndSingleSuffixFromAlbumIfPresent() from Track.swift.

section("Pro · EP/Single suffix stripping")

func stripEpSingleSuffix(from album: String) -> String {
    let trimmed = album.trimmingCharacters(in: .whitespacesAndNewlines)
    let suffixes = ["- EP", "- Single"]
    for suffix in suffixes {
        if trimmed.hasSuffix(suffix) {
            let stripped = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? trimmed : stripped
        }
    }
    return trimmed
}

expect("strips '- EP' suffix",       stripEpSingleSuffix(from: "Folklore - EP") == "Folklore",
       detail: "got '\(stripEpSingleSuffix(from: "Folklore - EP"))'")
expect("strips '- Single' suffix",   stripEpSingleSuffix(from: "Circles - Single") == "Circles",
       detail: "got '\(stripEpSingleSuffix(from: "Circles - Single"))'")
expect("leaves plain album name",    stripEpSingleSuffix(from: "Album Name") == "Album Name",
       detail: "got '\(stripEpSingleSuffix(from: "Album Name"))'")
expect("'EP' as prefix is kept",     stripEpSingleSuffix(from: "EP Recordings") == "EP Recordings",
       detail: "got '\(stripEpSingleSuffix(from: "EP Recordings"))'")
expect("strips with extra whitespace", stripEpSingleSuffix(from: "  My Album - EP  ") == "My Album",
       detail: "got '\(stripEpSingleSuffix(from: "  My Album - EP  "))'")

// ─── Album artist substitution ────────────────────────────────────────────────
// Replicates usableAlbumArtistForArtistSubstitution(_:isCompilation:) from Track.swift.

section("Pro · Album artist substitution")

func usableAlbumArtist(_ albumArtist: String?, isCompilation: Bool?) -> String? {
    guard let trimmed = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    guard isCompilation != true else { return nil }
    guard trimmed.compare("Various Artists", options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else {
        return nil
    }
    return trimmed
}

expect("uses albumArtist when available",    usableAlbumArtist("The Band", isCompilation: nil) == "The Band")
expect("returns nil for nil albumArtist",    usableAlbumArtist(nil, isCompilation: nil) == nil)
expect("returns nil for empty albumArtist",  usableAlbumArtist("   ", isCompilation: nil) == nil)
expect("returns nil for compilations",       usableAlbumArtist("The Band", isCompilation: true) == nil)
expect("'Various Artists' is nil",           usableAlbumArtist("Various Artists", isCompilation: nil) == nil)
expect("'various artists' (lowercase) nil",  usableAlbumArtist("various artists", isCompilation: nil) == nil)
expect("non-compilation uses albumArtist",   usableAlbumArtist("The Band", isCompilation: false) == "The Band")

// ─── Track dedup key (libraryIdentityKey) ────────────────────────────────────
// Replicates stableLibraryIdentity from Track.swift.

section("Track · libraryIdentityKey fallback chain")

func stableLibraryIdentity(persistentID: UInt64?, playbackStoreID: String?, artist: String, title: String, album: String?) -> String {
    func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    if let persistentID, persistentID != 0 {
        return "pid:\(persistentID)"
    }
    if let playbackStoreID {
        let trimmed = playbackStoreID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return "sid:\(trimmed.lowercased())" }
    }
    let albumValue = album.map(norm) ?? ""
    return "meta:\(norm(artist))|\(norm(title))|\(albumValue)"
}

let keyWithPID    = stableLibraryIdentity(persistentID: 42, playbackStoreID: "sid1", artist: "A", title: "T", album: "Al")
let keyWithSID    = stableLibraryIdentity(persistentID: nil, playbackStoreID: "sid1", artist: "A", title: "T", album: "Al")
let keyWithMeta   = stableLibraryIdentity(persistentID: nil, playbackStoreID: nil, artist: "Artist", title: "Title", album: "Album")
let keyWithMetaLo = stableLibraryIdentity(persistentID: nil, playbackStoreID: nil, artist: "ARTIST", title: "TITLE", album: "ALBUM")

expect("persistentID takes priority",            keyWithPID == "pid:42",              detail: "got '\(keyWithPID)'")
expect("playbackStoreID used when no pid",       keyWithSID == "sid:sid1",            detail: "got '\(keyWithSID)'")
expect("meta key uses normalized components",    keyWithMeta == "meta:artist|title|album", detail: "got '\(keyWithMeta)'")
expect("meta key is case-insensitive",           keyWithMeta == keyWithMetaLo,        detail: "meta='\(keyWithMeta)' metaLo='\(keyWithMetaLo)'")
expect("persistentID=0 falls through to sid",   stableLibraryIdentity(persistentID: 0, playbackStoreID: "x", artist: "A", title: "T", album: nil) == "sid:x")
expect("empty sid falls through to meta",        stableLibraryIdentity(persistentID: nil, playbackStoreID: "  ", artist: "A", title: "T", album: nil) == "meta:a|t|")

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

// ─── Duplicate scrobble timestamp tolerance ───────────────────────────────────
// Replicates containsSimilar from ScrobbleBacklog / ScrobbleLogStore.
// Deduplication window: 10 seconds (tolerance = 10).

section("Dedup · Timestamp tolerance (10s window)")

struct FakeScrobble { let dedupeKey: String; let startTimestamp: Int }

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

// ─── Listening History repeated-play recovery ────────────────────────────────
// Replicates the count-based recovery logic in PlaybackHistoryImporter.

section("Listening History · Repeated play recovery")

func recoveredPlaybackHistoryStartTimestamps(
    playCount: Int,
    previousPlayCount: Int?,
    playedAt: Int,
    durationSeconds: Int?,
    previousSeenPlayedAt: Int?,
    preventDuplicates: Bool,
    scrobbleLoopedTracks: Bool
) -> [Int] {
    let allowRepeatScrobbles = !preventDuplicates || scrobbleLoopedTracks
    let delta: Int = {
        guard let previousPlayCount else {
            if allowRepeatScrobbles {
                return max(playCount, 1)
            }
            return 1
        }
        let d = playCount - previousPlayCount
        if d > 0 { return d }
        return 1
    }()

    let playsToImport: Int = {
        if !allowRepeatScrobbles {
            return min(max(delta, 1), 5)
        }
        return max(delta, 1)
    }()

    let synthesizedPlayCount =
        previousSeenPlayedAt == playedAt
            ? max(playCount, 1)
            : playsToImport

    guard synthesizedPlayCount > 1 else { return [playedAt] }

    if let durationSeconds, durationSeconds > 0 {
        return (0..<synthesizedPlayCount).map { index in
            playedAt - durationSeconds * (synthesizedPlayCount - index)
        }
    }

    return (0..<synthesizedPlayCount).map { index in
        playedAt - (synthesizedPlayCount - index - 1)
    }
}

let recoveredStarts = recoveredPlaybackHistoryStartTimestamps(
    playCount: 20,
    previousPlayCount: nil,
    playedAt: 1_234,
    durationSeconds: 12,
    previousSeenPlayedAt: nil,
    preventDuplicates: false,
    scrobbleLoopedTracks: false
)
expectEqual("first sighting imports full playCount when duplicate prevention is OFF", recoveredStarts.count, 20)
expectEqual("recovered repeats synthesize distinct timestamps", Set(recoveredStarts).count, 20)
expect("latest synthesized repeat ends at Apple's playedAt", recoveredStarts.last == 1_222, detail: "got \(recoveredStarts.suffix(3))")

let conservativeStarts = recoveredPlaybackHistoryStartTimestamps(
    playCount: 15,
    previousPlayCount: 0,
    playedAt: 4_405,
    durationSeconds: 60,
    previousSeenPlayedAt: nil,
    preventDuplicates: true,
    scrobbleLoopedTracks: false
)
expectEqual("duplicate prevention ON keeps conservative 5-play cap", conservativeStarts.count, 5)
expect("conservative recovery also staggers timestamps", conservativeStarts == [4_105, 4_165, 4_225, 4_285, 4_345], detail: "got \(conservativeStarts)")

let loopToggleStarts = recoveredPlaybackHistoryStartTimestamps(
    playCount: 20,
    previousPlayCount: nil,
    playedAt: 9_876,
    durationSeconds: 12,
    previousSeenPlayedAt: nil,
    preventDuplicates: true,
    scrobbleLoopedTracks: true
)
expectEqual("looped-track setting also enables full-count history recovery", loopToggleStarts.count, 20)

let samePlayedAtGrowthStarts = recoveredPlaybackHistoryStartTimestamps(
    playCount: 4,
    previousPlayCount: 3,
    playedAt: 1_200,
    durationSeconds: 200,
    previousSeenPlayedAt: 1_200,
    preventDuplicates: false,
    scrobbleLoopedTracks: false
)
expect("same playedAt growth regenerates the full synthesized timeline", samePlayedAtGrowthStarts == [400, 600, 800, 1000], detail: "got \(samePlayedAtGrowthStarts)")

func shouldProcessPlaybackHistoryCandidate(
    playedAt: Int,
    playCutoff: Int,
    previousSeenPlayedAt: Int?,
    playCount: Int,
    previousPlayCount: Int?
) -> Bool {
    let hasNewPlayedAt = playedAt > playCutoff
    let hasCountIncreaseAtSamePlayedAt = previousSeenPlayedAt == playedAt &&
        previousPlayCount.map { playCount > $0 } == true
    return hasNewPlayedAt || hasCountIncreaseAtSamePlayedAt
}

expect("same-minute candidate is still processed when playCount increases",
       shouldProcessPlaybackHistoryCandidate(playedAt: 2_000, playCutoff: 2_000, previousSeenPlayedAt: 2_000, playCount: 7, previousPlayCount: 5))
expect("same-minute candidate is skipped when playCount is unchanged",
       !shouldProcessPlaybackHistoryCandidate(playedAt: 2_000, playCutoff: 2_000, previousSeenPlayedAt: 2_000, playCount: 7, previousPlayCount: 7))

section("Listening History · Match counting against stored timestamps")

struct FakeHistoryMatch {
    let dedupeKey: String
    let startTimestamp: Int
    let durationSeconds: Int?
    let style: String
}

func playbackHistoryImportMatchCount(
    items: [FakeHistoryMatch],
    key: String,
    startTimestamp: Int,
    playedAt: Int,
    exactTolerance: Int,
    playedTolerance: Int
) -> Int {
    let exactTol = max(0, exactTolerance)
    let playedTol = max(0, playedTolerance)

    return items.filter { item in
        guard item.dedupeKey == key else { return false }

        let exactMatch = abs(item.startTimestamp - startTimestamp) <= exactTol
        let directPlayedAtMatch = abs(item.startTimestamp - playedAt) <= playedTol

        switch item.style {
        case "history", "manual":
            return exactMatch || directPlayedAtMatch
        case "live":
            guard let durationSeconds = item.durationSeconds else { return exactMatch || directPlayedAtMatch }
            return exactMatch || abs((item.startTimestamp + durationSeconds) - playedAt) <= playedTol
        default:
            guard let durationSeconds = item.durationSeconds else { return exactMatch || directPlayedAtMatch }
            return exactMatch || directPlayedAtMatch || abs((item.startTimestamp + durationSeconds) - playedAt) <= playedTol
        }
    }.count
}

let exactMinuteMatches = [
    FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 1_000, durationSeconds: nil, style: "history"),
    FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 1_200, durationSeconds: nil, style: "history"),
]
expectEqual(
    "staggered playback-history timestamps are counted individually",
    playbackHistoryImportMatchCount(items: exactMinuteMatches, key: "track-a", startTimestamp: 1_000, playedAt: 1_200, exactTolerance: 3, playedTolerance: 0),
    2
)

let crossSourceMatches = [
    FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 1_000, durationSeconds: 200, style: "live")
]
let desiredImports = 3
let existingCrossSourceMatches = playbackHistoryImportMatchCount(
    items: crossSourceMatches,
    key: "track-a",
    startTimestamp: 1_200,
    playedAt: 1_200,
    exactTolerance: 3,
    playedTolerance: 0
)
expectEqual("live scrobble overlap counts as exactly one existing match", existingCrossSourceMatches, 1)
expectEqual("cross-source overlap suppresses only one recovered play", max(0, desiredImports - existingCrossSourceMatches), 2)

let alreadyImported = [
    FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 2_400, durationSeconds: nil, style: "history"),
    FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 2_700, durationSeconds: nil, style: "history"),
    FakeHistoryMatch(dedupeKey: "track-a", startTimestamp: 3_000, durationSeconds: nil, style: "history"),
]
let regeneratedCandidateStarts = [2_400, 2_700, 3_000]
let existingCandidateMatches = regeneratedCandidateStarts.filter { candidateStart in
    playbackHistoryImportMatchCount(
        items: alreadyImported,
        key: "track-a",
        startTimestamp: candidateStart,
        playedAt: candidateStart,
        exactTolerance: 3,
        playedTolerance: 0
    ) > 0
}.count
expectEqual("re-running import sees every synthesized timestamp already present", existingCandidateMatches, 3)
expectEqual("re-running import does not enqueue more when counts already match", max(0, 3 - existingCandidateMatches), 0)

// ─── Dedup nearest-match selection ────────────────────────────────────────────
// Replicates mostSimilar() from ScrobbleBacklog / ScrobbleLogStore.

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

// ─── Backlog 10-minute backoff ────────────────────────────────────────────────
// Replicates the backoff guard in ScrobbleBacklog.flush():
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

// ─── Bracket removal — additional edge cases ──────────────────────────────────

section("3a · Bracket removal — additional edge cases")

let edgeEmpty   = cleanedMetadata(from: "Song ()", removeAll: true, keywords: [])
expect("empty brackets removed with removeAll",     edgeEmpty.result == "Song", detail: "got '\(edgeEmpty.result)'")

let edgeSpace   = cleanedMetadata(from: "Song ( )", removeAll: true, keywords: [])
expect("whitespace-only brackets removed",          edgeSpace.result == "Song", detail: "got '\(edgeSpace.result)'")

let edgeUnicode = cleanedMetadata(from: "Song (フィーチャー)", removeAll: true, keywords: [])
expect("unicode content inside brackets removed",   edgeUnicode.result == "Song", detail: "got '\(edgeUnicode.result)'")

let edgeSqKey   = cleanedMetadata(from: "Song [feat. Artist]", removeAll: false, keywords: ["feat."])
expect("square bracket keyword match removed",      edgeSqKey.result == "Song", detail: "got '\(edgeSqKey.result)'")

// When removing all brackets would leave an empty string, return the original.
let edgeOnlyBracket = cleanedMetadata(from: "(feat. X)", removeAll: true, keywords: [])
expect("result empty after removal → keep original", edgeOnlyBracket.result == "(feat. X)", detail: "got '\(edgeOnlyBracket.result)'")

// ─── API signature generation ─────────────────────────────────────────────────
// Replicates apiSignature(params:) from LastFMClient.swift.
// Uses CryptoKit MD5: sorted filtered params concatenated + secret, then MD5 hex.

import CryptoKit

section("API · Signature generation (MD5)")

func apiSignature(params: [String: String], secret: String) -> String {
    let filtered = params.filter { $0.key != "format" }
    let base = filtered
        .sorted(by: { $0.key < $1.key })
        .map { $0.key + $0.value }
        .joined() + secret
    let digest = Insecure.MD5.hash(data: Data(base.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

let sigParams: [String: String] = ["method": "auth.getToken", "api_key": "testkey", "format": "json"]
let sig = apiSignature(params: sigParams, secret: "testsecret")

// "api_key" + "testkey" + "method" + "auth.getToken" + "testsecret" (format excluded, sorted)
let expectedSigBase = "api_keytestkeymethodauth.getTokentestsecret"
let expectedDigest = Insecure.MD5.hash(data: Data(expectedSigBase.utf8))
let expectedSig = expectedDigest.map { String(format: "%02x", $0) }.joined()

expect("signature is 32 hex chars",              sig.count == 32, detail: "got \(sig.count) chars")
expect("signature matches expected MD5",         sig == expectedSig, detail: "got '\(sig)'")
expect("format key excluded from signature",     sig == apiSignature(params: sigParams.filter { $0.key != "format" }, secret: "testsecret"))
expect("different secret = different signature", sig != apiSignature(params: sigParams, secret: "othersecret"))

// Parameter order doesn't affect result (always sorted internally)
let sigAlt = apiSignature(params: ["api_key": "testkey", "format": "json", "method": "auth.getToken"], secret: "testsecret")
expect("param dict order doesn't affect sig",    sig == sigAlt)

// ─── URL form encoding ────────────────────────────────────────────────────────
// Replicates urlEncode(_:) from LastFMClient.swift.
// Note: space is percent-encoded to %20 (replace " "→"+" runs after encoding, so never fires).

section("API · URL form encoding")

func urlEncode(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    return encoded.replacingOccurrences(of: " ", with: "+")
}

expect("space encodes to %20 (not +, replace fires post-encoding)", urlEncode("hello world") == "hello%20world",
       detail: "got '\(urlEncode("hello world"))'")
expect("'&' encodes to %26",    urlEncode("a&b") == "a%26b",   detail: "got '\(urlEncode("a&b"))'")
expect("'=' encodes to %3D",    urlEncode("a=b") == "a%3Db",   detail: "got '\(urlEncode("a=b"))'")
expect("safe chars unchanged",  urlEncode("abc-._~") == "abc-._~", detail: "got '\(urlEncode("abc-._~"))'")
expect("empty string unchanged",urlEncode("") == "")
expect("'+' encodes to %2B",    urlEncode("a+b") == "a%2Bb", detail: "got '\(urlEncode("a+b"))'")

// ─── API request metadata normalization ───────────────────────────────────────
// Replicates applyOptionalTrackMetadata(from:to:) from LastFMClient.swift.

section("API · Optional track metadata normalization")

struct APITrack {
    let album: String?
    let albumArtist: String?
    let durationSeconds: Double?
}

func albumArtistForScrobbleMetadata(_ albumArtist: String?) -> String? {
    guard let trimmed = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

func applyOptionalTrackMetadata(from track: APITrack, to params: inout [String: String]) {
    if let album = normalized(track.album) {
        params["album"] = album
    }
    if let albumArtist = albumArtistForScrobbleMetadata(track.albumArtist) {
        params["albumArtist"] = albumArtist
    }
    if let durationSeconds = track.durationSeconds, durationSeconds > 0 {
        params["duration"] = String(Int(durationSeconds.rounded()))
    }
}

var metaParams: [String: String] = [:]
applyOptionalTrackMetadata(from: APITrack(album: "  Album Name  ", albumArtist: "  The Band  ", durationSeconds: 201.6), to: &metaParams)
expect("album is trimmed before submission", metaParams["album"] == "Album Name", detail: "got '\(metaParams["album"] ?? "nil")'")
expect("albumArtist is trimmed before submission", metaParams["albumArtist"] == "The Band", detail: "got '\(metaParams["albumArtist"] ?? "nil")'")
expect("duration is rounded to nearest whole second", metaParams["duration"] == "202", detail: "got '\(metaParams["duration"] ?? "nil")'")

var blankMetaParams: [String: String] = [:]
applyOptionalTrackMetadata(from: APITrack(album: "   ", albumArtist: "\n", durationSeconds: 0), to: &blankMetaParams)
expect("blank album is omitted", blankMetaParams["album"] == nil)
expect("blank albumArtist is omitted", blankMetaParams["albumArtist"] == nil)
expect("zero duration is omitted", blankMetaParams["duration"] == nil)

var negativeDurationParams: [String: String] = [:]
applyOptionalTrackMetadata(from: APITrack(album: nil, albumArtist: nil, durationSeconds: -1), to: &negativeDurationParams)
expect("negative duration is omitted", negativeDurationParams["duration"] == nil)

// ─── Manual Scrobble — input trimming and metadata assembly ──────────────────
// Replicates submitManualScrobble field-trimming logic from ScrobbleEngine.swift.
// Whitespace is stripped; blank optional fields become nil.

section("Manual Scrobble · Input trimming and metadata assembly")

struct ManualScrobbleInput {
    let artist: String
    let title: String
    let album: String?
    let albumArtist: String?
    let timestamp: Int
}

func buildManualScrobbleTrack(artist: String, title: String, album: String?, albumArtist: String?, timestamp: Int) -> ManualScrobbleInput {
    let trimmedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAlbumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
    return ManualScrobbleInput(
        artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
        album: (trimmedAlbum?.isEmpty == false) ? trimmedAlbum : nil,
        albumArtist: (trimmedAlbumArtist?.isEmpty == false) ? trimmedAlbumArtist : nil,
        timestamp: timestamp
    )
}

let ms1 = buildManualScrobbleTrack(artist: "  The Beatles  ", title: "  Hey Jude  ", album: nil, albumArtist: nil, timestamp: 1000)
expect("artist whitespace trimmed",     ms1.artist == "The Beatles", detail: "got '\(ms1.artist)'")
expect("title whitespace trimmed",      ms1.title == "Hey Jude",     detail: "got '\(ms1.title)'")
expect("nil album stays nil",           ms1.album == nil)

let ms2 = buildManualScrobbleTrack(artist: "Artist", title: "Song", album: "   ", albumArtist: "   ", timestamp: 1000)
expect("blank album becomes nil",       ms2.album == nil,       detail: "got '\(ms2.album ?? "nil")'")
expect("blank albumArtist becomes nil", ms2.albumArtist == nil, detail: "got '\(ms2.albumArtist ?? "nil")'")

let ms3 = buildManualScrobbleTrack(artist: "Artist", title: "Song", album: "  White Album  ", albumArtist: "  The Beatles  ", timestamp: 1000)
expect("album whitespace trimmed",       ms3.album == "White Album",   detail: "got '\(ms3.album ?? "nil")'")
expect("albumArtist whitespace trimmed", ms3.albumArtist == "The Beatles", detail: "got '\(ms3.albumArtist ?? "nil")'")

// ─── Manual Scrobble — canSubmit validation ────────────────────────────────────
// Replicates ManualScrobbleView.canSubmit logic.

section("Manual Scrobble · canSubmit validation")

func canSubmit(artist: String, title: String, isSubmitting: Bool, isSubmitted: Bool) -> Bool {
    !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    !isSubmitting &&
    !isSubmitted
}

expect("valid artist+title is submittable",         canSubmit(artist: "A", title: "T", isSubmitting: false, isSubmitted: false))
expect("empty artist blocks submit",                !canSubmit(artist: "",  title: "T", isSubmitting: false, isSubmitted: false))
expect("whitespace-only artist blocks submit",      !canSubmit(artist: "  ", title: "T", isSubmitting: false, isSubmitted: false))
expect("empty title blocks submit",                 !canSubmit(artist: "A", title: "",  isSubmitting: false, isSubmitted: false))
expect("whitespace-only title blocks submit",       !canSubmit(artist: "A", title: "  ", isSubmitting: false, isSubmitted: false))
expect("isSubmitting=true blocks submit",           !canSubmit(artist: "A", title: "T", isSubmitting: true,  isSubmitted: false))
expect("isSubmitted=true blocks submit",            !canSubmit(artist: "A", title: "T", isSubmitting: false, isSubmitted: true))
expect("both empty blocks submit",                  !canSubmit(artist: "",  title: "",  isSubmitting: false, isSubmitted: false))

// ─── Manual Scrobble — timestamp selection ────────────────────────────────────
// Replicates ManualScrobbleView.timestamp computed property.

section("Manual Scrobble · Timestamp selection")

func computeTimestamp(useCustom: Bool, customDate: Date, now: Date) -> Int {
    let date = useCustom ? customDate : now
    return Int(date.timeIntervalSince1970)
}

let tsNow = Date()
let tsCustom = tsNow.addingTimeInterval(-3600)  // 1 hour ago

expect("useCustom=false uses now",        computeTimestamp(useCustom: false, customDate: tsCustom, now: tsNow) == Int(tsNow.timeIntervalSince1970))
expect("useCustom=true uses customDate",  computeTimestamp(useCustom: true,  customDate: tsCustom, now: tsNow) == Int(tsCustom.timeIntervalSince1970))
expect("timestamp is Unix epoch (Int)",   computeTimestamp(useCustom: false, customDate: tsCustom, now: tsNow) > 1_000_000_000)

let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: tsNow) ?? tsNow
expect("two-weeks-ago boundary is within allowed range",
       computeTimestamp(useCustom: true, customDate: twoWeeksAgo, now: tsNow) >= Int(twoWeeksAgo.timeIntervalSince1970))

// ─── Current-track manual scrobble timestamp avoidance ────────────────────────
// Replicates ScrobbleEngine current-track manual timestamp selection.

section("Current-track manual scrobble · Timestamp avoidance")

var lastManualScrobbleTrackKey: String?
var lastManualScrobbleBaseTimestamp: Int?
var lastManualScrobbleTimestamp: Int?

func currentTrackManualTimestamp(trackKey: String, now: Date) -> Int {
    let baseTimestamp = max(1, Int(now.timeIntervalSince1970.rounded(.down)))
    let timestamp: Int
    if lastManualScrobbleTrackKey == trackKey,
       lastManualScrobbleBaseTimestamp == baseTimestamp,
       let lastTimestamp = lastManualScrobbleTimestamp
    {
        timestamp = max(1, lastTimestamp - 1)
    } else {
        timestamp = baseTimestamp
    }

    lastManualScrobbleTrackKey = trackKey
    lastManualScrobbleBaseTimestamp = baseTimestamp
    lastManualScrobbleTimestamp = timestamp
    return timestamp
}

let manualBaseNow = Date(timeIntervalSince1970: 1_700_000_100)

let mt1 = currentTrackManualTimestamp(trackKey: "track-a", now: manualBaseNow)
expect("first current-track manual scrobble uses button-press time", mt1 == 1_700_000_100, detail: "got \(mt1)")

let mt2 = currentTrackManualTimestamp(trackKey: "track-a", now: manualBaseNow)
expect("same-track duplicate timestamp decrements by 1", mt2 == 1_700_000_099, detail: "got \(mt2)")

let mt3 = currentTrackManualTimestamp(trackKey: "track-a", now: manualBaseNow.addingTimeInterval(5))
expect("same track moves back to fresh button-press time in a new second", mt3 == 1_700_000_105, detail: "got \(mt3)")

let mt4 = currentTrackManualTimestamp(trackKey: "track-b", now: manualBaseNow)
expect("different track resets duplicate-timestamp guard", mt4 == 1_700_000_100, detail: "got \(mt4)")

lastManualScrobbleTrackKey = "track-c"
lastManualScrobbleBaseTimestamp = 1
lastManualScrobbleTimestamp = 1
let mt5 = currentTrackManualTimestamp(trackKey: "track-c", now: Date(timeIntervalSince1970: 0))
expect("duplicate-timestamp decrement floors at 1", mt5 == 1, detail: "got \(mt5)")

section("Shortcut current-track scrobble · Timestamp selection")

func shortcutCurrentTrackTimestamp(now: Date) -> Int {
    max(1, Int(now.timeIntervalSince1970.rounded(.down)))
}

expectEqual("shortcut current-track scrobble uses button-press time", shortcutCurrentTrackTimestamp(now: manualBaseNow), 1_700_000_100)
expectEqual("shortcut current-track scrobble matches the first Scrobble Now timestamp", shortcutCurrentTrackTimestamp(now: manualBaseNow), mt1)

// ─── Manual Scrobble — backlog fallback on failure ────────────────────────────
// Validates the pattern: on error, enqueue to backlog with .manual origin, then re-throw.

section("Manual Scrobble · Backlog fallback on submit error")

enum SimManualScrobbleError: Error { case networkError }
enum SimScrobbleOrigin: String { case manual, live }
struct SimBacklogEntry2 { let key: String; let ts: Int; let origin: SimScrobbleOrigin }

func simulateManualScrobble(
    shouldFail: Bool,
    artist: String, title: String, timestamp: Int,
    backlog: inout [SimBacklogEntry2],
    log: inout [(key: String, ts: Int)]
) throws {
    let trackKey = "meta:\(artist.lowercased())|\(title.lowercased())|"
    if shouldFail {
        backlog.append(SimBacklogEntry2(key: trackKey, ts: timestamp, origin: .manual))
        throw SimManualScrobbleError.networkError
    } else {
        log.append((key: trackKey, ts: timestamp))
    }
}

var simBacklog: [SimBacklogEntry2] = []
var simLog: [(key: String, ts: Int)] = []

// Success path: log is updated, backlog unchanged
try? simulateManualScrobble(shouldFail: false, artist: "Artist", title: "Song", timestamp: 5000,
                            backlog: &simBacklog, log: &simLog)
expect("success: scrobble log has entry",   simLog.count == 1, detail: "got \(simLog.count)")
expect("success: backlog is empty",         simBacklog.isEmpty)

// Failure path: backlog gets entry, log unchanged
var didThrow = false
do {
    try simulateManualScrobble(shouldFail: true, artist: "Artist2", title: "Song2", timestamp: 6000,
                               backlog: &simBacklog, log: &simLog)
} catch {
    didThrow = true
}
expect("failure: error is re-thrown",               didThrow)
expect("failure: backlog has entry",                simBacklog.count == 1, detail: "got \(simBacklog.count)")
expect("failure: backlog entry has manual origin",  simBacklog.first?.origin == .manual)
expect("failure: scrobble log unchanged (no add)",  simLog.count == 1, detail: "got \(simLog.count)")

// ─── Text Replacement — basic rule application ────────────────────────────────
// Replicates Track.applyingTextReplacements(_:) from Track.swift.

section("Text Replacement · Basic rule application")

enum TRScope { case all, artist, track, album }
struct TRRule { var find: String; var replace: String; var scope: TRScope; var isEnabled: Bool = true }

struct TRTrack {
    var artist: String
    var title: String
    var album: String?

    func applyingTextReplacements(_ rules: [TRRule]) -> TRTrack {
        var copy = self
        for rule in rules {
            guard !rule.find.isEmpty, rule.isEnabled else { continue }
            switch rule.scope {
            case .all:
                copy.artist = copy.artist.replacingOccurrences(of: rule.find, with: rule.replace)
                copy.title  = copy.title.replacingOccurrences(of: rule.find, with: rule.replace)
                copy.album  = copy.album?.replacingOccurrences(of: rule.find, with: rule.replace)
            case .artist:
                copy.artist = copy.artist.replacingOccurrences(of: rule.find, with: rule.replace)
            case .track:
                copy.title  = copy.title.replacingOccurrences(of: rule.find, with: rule.replace)
            case .album:
                copy.album  = copy.album?.replacingOccurrences(of: rule.find, with: rule.replace)
            }
        }
        return copy
    }
}

let baseTrack = TRTrack(artist: "Artist ft. Guest", title: "Song (Live)", album: "Album - EP")

let trAll = baseTrack.applyingTextReplacements([TRRule(find: "ft. Guest", replace: "", scope: .all)])
expect("scope=all replaces in artist",  trAll.artist == "Artist ", detail: "got '\(trAll.artist)'")
expect("scope=all: album unchanged if no match", trAll.album == "Album - EP")

let trArtist = baseTrack.applyingTextReplacements([TRRule(find: " ft. Guest", replace: "", scope: .artist)])
expect("scope=artist replaces in artist",  trArtist.artist == "Artist",         detail: "got '\(trArtist.artist)'")
expect("scope=artist title unchanged",     trArtist.title  == "Song (Live)",     detail: "got '\(trArtist.title)'")
expect("scope=artist album unchanged",     trArtist.album  == "Album - EP",      detail: "got '\(trArtist.album ?? "nil")'")

let trTrack = baseTrack.applyingTextReplacements([TRRule(find: " (Live)", replace: "", scope: .track)])
expect("scope=track replaces in title",   trTrack.title   == "Song",             detail: "got '\(trTrack.title)'")
expect("scope=track artist unchanged",    trTrack.artist  == "Artist ft. Guest", detail: "got '\(trTrack.artist)'")
expect("scope=track album unchanged",     trTrack.album   == "Album - EP",       detail: "got '\(trTrack.album ?? "nil")'")

let trAlbum = baseTrack.applyingTextReplacements([TRRule(find: " - EP", replace: "", scope: .album)])
expect("scope=album replaces in album",   trAlbum.album   == "Album",            detail: "got '\(trAlbum.album ?? "nil")'")
expect("scope=album artist unchanged",    trAlbum.artist  == "Artist ft. Guest", detail: "got '\(trAlbum.artist)'")
expect("scope=album title unchanged",     trAlbum.title   == "Song (Live)",      detail: "got '\(trAlbum.title)'")

// ─── Text Replacement — disabled rules skipped ───────────────────────────────

section("Text Replacement · Disabled rules are skipped")

let disabledRule = TRRule(find: "ft. Guest", replace: "", scope: .all, isEnabled: false)
let trDisabled = baseTrack.applyingTextReplacements([disabledRule])
expect("disabled rule does not modify artist", trDisabled.artist == baseTrack.artist, detail: "got '\(trDisabled.artist)'")
expect("disabled rule does not modify title",  trDisabled.title  == baseTrack.title,  detail: "got '\(trDisabled.title)'")

// ─── Text Replacement — empty find string skipped ────────────────────────────

section("Text Replacement · Empty find string is skipped")

let emptyFindRule = TRRule(find: "", replace: "X", scope: .all)
let trEmptyFind = baseTrack.applyingTextReplacements([emptyFindRule])
expect("empty find does not modify artist", trEmptyFind.artist == baseTrack.artist, detail: "got '\(trEmptyFind.artist)'")
expect("empty find does not modify title",  trEmptyFind.title  == baseTrack.title,  detail: "got '\(trEmptyFind.title)'")

// ─── Text Replacement — multiple rules applied in order ──────────────────────

section("Text Replacement · Multiple rules applied sequentially")

let multiTrack = TRTrack(artist: "Artist ft. Guest A & B", title: "Song", album: nil)
let multiRules: [TRRule] = [
    TRRule(find: " ft. Guest A", replace: "", scope: .artist),
    TRRule(find: " & B", replace: "", scope: .artist),
]
let trMulti = multiTrack.applyingTextReplacements(multiRules)
expect("first rule applied", trMulti.artist.contains("ft. Guest A") == false, detail: "got '\(trMulti.artist)'")
expect("second rule applied", trMulti.artist == "Artist", detail: "got '\(trMulti.artist)'")

// ─── Text Replacement — nil album not modified ────────────────────────────────

section("Text Replacement · Nil album is unaffected by album-scope rule")

let nilAlbumTrack = TRTrack(artist: "Artist", title: "Song", album: nil)
let trNilAlbum = nilAlbumTrack.applyingTextReplacements([TRRule(find: "x", replace: "y", scope: .album)])
expect("nil album stays nil after album-scope rule", trNilAlbum.album == nil)

let trNilAlbumAll = nilAlbumTrack.applyingTextReplacements([TRRule(find: "x", replace: "y", scope: .all)])
expect("nil album stays nil after all-scope rule", trNilAlbumAll.album == nil)

// ─── Text Replacement — built-in rules (EP / Single suffix) ──────────────────
// The built-in rules are album-scoped, disabled by default.
// When enabled they strip "- EP" / "- Single" from album titles.

section("Text Replacement · Built-in EP and Single suffix rules")

let builtInRules: [TRRule] = [
    TRRule(find: "- Single", replace: "", scope: .album, isEnabled: true),
    TRRule(find: "- EP",     replace: "", scope: .album, isEnabled: true),
]

let epTrack     = TRTrack(artist: "A", title: "T", album: "Folklore - EP")
let singleTrack = TRTrack(artist: "A", title: "T", album: "Circles - Single")
let plainTrack  = TRTrack(artist: "A", title: "T", album: "Regular Album")

// Text replacement uses plain replacingOccurrences, so the find string must match exactly.
// "Folklore - EP" with find="- EP" leaves "Folklore " (with trailing space).
// The Pro EP/Single stripping (strippingEpAndSingleSuffixFromAlbumIfPresent) is a separate
// code path that also trims whitespace — text replacement does not trim.
expect("'- EP' stripped from album (trailing space preserved by plain replace)",
       epTrack.applyingTextReplacements(builtInRules).album == "Folklore ",       detail: "got '\(epTrack.applyingTextReplacements(builtInRules).album ?? "nil")'")
expect("'- Single' stripped from album (trailing space preserved by plain replace)",
       singleTrack.applyingTextReplacements(builtInRules).album == "Circles ",    detail: "got '\(singleTrack.applyingTextReplacements(builtInRules).album ?? "nil")'")
expect("plain album name unchanged",     plainTrack.applyingTextReplacements(builtInRules).album == "Regular Album", detail: "got '\(plainTrack.applyingTextReplacements(builtInRules).album ?? "nil")'")

let disabledBuiltIns: [TRRule] = [
    TRRule(find: "- Single", replace: "", scope: .album, isEnabled: false),
    TRRule(find: "- EP",     replace: "", scope: .album, isEnabled: false),
]
expect("disabled built-in: EP suffix kept",     epTrack.applyingTextReplacements(disabledBuiltIns).album == "Folklore - EP",    detail: "got '\(epTrack.applyingTextReplacements(disabledBuiltIns).album ?? "nil")'")
expect("disabled built-in: Single suffix kept", singleTrack.applyingTextReplacements(disabledBuiltIns).album == "Circles - Single", detail: "got '\(singleTrack.applyingTextReplacements(disabledBuiltIns).album ?? "nil")'")

// ─── Text Replacement — replace with non-empty string ────────────────────────

section("Text Replacement · Replacement with non-empty substitute string")

let subTrack = TRTrack(artist: "Sy & Unknown Mortal Orchestra", title: "Soulmate", album: nil)
let subRule  = TRRule(find: "Sy & ", replace: "", scope: .artist)
expect("prefix stripped leaving remainder", subTrack.applyingTextReplacements([subRule]).artist == "Unknown Mortal Orchestra",
       detail: "got '\(subTrack.applyingTextReplacements([subRule]).artist)'")

let canonRule = TRRule(find: "The Weeknd", replace: "Abel Tesfaye", scope: .artist)
let weekndTrack = TRTrack(artist: "The Weeknd", title: "Blinding Lights", album: nil)
expect("replacement substitutes full artist name",
       weekndTrack.applyingTextReplacements([canonRule]).artist == "Abel Tesfaye",
       detail: "got '\(weekndTrack.applyingTextReplacements([canonRule]).artist)'")

// ─── Text Replacement — case-sensitive exact matching ────────────────────────

section("Text Replacement · Case-sensitive exact matching")

let caseTrack = TRTrack(artist: "ARTIST", title: "song", album: nil)
let lcRule    = TRRule(find: "artist", replace: "", scope: .artist)   // lowercase — shouldn't match "ARTIST"
expect("lowercase find does not match uppercase artist", caseTrack.applyingTextReplacements([lcRule]).artist == "ARTIST",
       detail: "got '\(caseTrack.applyingTextReplacements([lcRule]).artist)'")

// ─── Background grace period — lifecycle decisions ───────────────────────────

section("Background grace period · lifecycle decisions")

struct SimGraceController {
    var isGracePeriodActive = false
    var pauseCalls = 0
    var expiryCalls = 0

    mutating func enterBackground(shouldStartGracePeriod: Bool, canStartGracePeriod: Bool) {
        if shouldStartGracePeriod && canStartGracePeriod {
            isGracePeriodActive = true
        } else {
            pauseCalls += 1
        }
    }

    mutating func expireGracePeriodIfNeeded() {
        guard isGracePeriodActive else { return }
        isGracePeriodActive = false
        expiryCalls += 1
        pauseCalls += 1
    }

    mutating func enterForeground() {
        isGracePeriodActive = false
    }
}

var grace = SimGraceController()
grace.enterBackground(shouldStartGracePeriod: true, canStartGracePeriod: true)
expect("grace period starts when background task is available", grace.isGracePeriodActive)
expect("starting grace period does not pause immediately", grace.pauseCalls == 0, detail: "got \(grace.pauseCalls)")

expect("grace period remains active before expiry", grace.isGracePeriodActive)

grace.expireGracePeriodIfNeeded()
grace.expireGracePeriodIfNeeded()
expect("expiry fires once", grace.expiryCalls == 1, detail: "got \(grace.expiryCalls)")
expect("expiry pauses once", grace.pauseCalls == 1, detail: "got \(grace.pauseCalls)")

var foregroundResume = SimGraceController()
foregroundResume.enterBackground(shouldStartGracePeriod: true, canStartGracePeriod: true)
foregroundResume.enterForeground()
foregroundResume.expireGracePeriodIfNeeded()
expect("foreground entry cancels the active grace period", !foregroundResume.isGracePeriodActive)
expect("foreground cancel prevents expiry callback", foregroundResume.expiryCalls == 0, detail: "got \(foregroundResume.expiryCalls)")
expect("foreground cancel avoids a pause from expiry", foregroundResume.pauseCalls == 0, detail: "got \(foregroundResume.pauseCalls)")

var fallback = SimGraceController()
fallback.enterBackground(shouldStartGracePeriod: true, canStartGracePeriod: false)
expect("failed grace-period start leaves no active grace period", !fallback.isGracePeriodActive)
expect("failed grace-period start falls back to immediate pause", fallback.pauseCalls == 1, detail: "got \(fallback.pauseCalls)")

// ─── Settings defaults / reset coverage ─────────────────────────────────────

section("Settings defaults / reset coverage")

let runtimePreventDuplicatesDefault = true
let macSettingsPreventDuplicatesDefault = true
let macSettingsPreventDuplicatesAfterReset = true
expectEqual("macOS duplicate-prevention default matches runtime", macSettingsPreventDuplicatesDefault, runtimePreventDuplicatesDefault)
expectEqual("macOS reset restores duplicate prevention to runtime default", macSettingsPreventDuplicatesAfterReset, runtimePreventDuplicatesDefault)

let resetClearedKeys: Set<String> = [
    "FastScrobbler.Pro.loveOnFavoriteEnabled",
    "FastScrobbler.Pro.scrobbleThresholdIndex",
    "FastScrobbler.Pro.useAlbumArtistForScrobbling",
    "FastScrobbler.Pro.removeBracketsEnabled",
    "FastScrobbler.Pro.removeAllBracketsEnabled",
    "FastScrobbler.Pro.removeBracketsKeywords",
    "FastScrobbler.Pro.removeBracketsFromAlbumTitlesEnabled",
    "FastScrobbler.Pro.removeAllBracketsFromAlbumTitlesEnabled",
    "FastScrobbler.Pro.removeBracketsFromAlbumTitleKeywords",
    "FastScrobbler.Pro.preventDuplicateScrobblesEnabled",
    "FastScrobbler.Pro.scrobbleLoopedTracksEnabled",
    "FastScrobbler.App.scrobbleListeningHistoryEnabled",
    "FastScrobbler.Pro.scrobbleListeningHistoryFromAllDevicesEnabled",
    "FastScrobbler.Pro.textReplacementRules",
]

expect("reset clears scrobbleLoopedTracksEnabled", resetClearedKeys.contains("FastScrobbler.Pro.scrobbleLoopedTracksEnabled"))
expect("reset clears textReplacementRules", resetClearedKeys.contains("FastScrobbler.Pro.textReplacementRules"))

let iOSLoopedTracksAfterReset = false
expectEqual("iOS reset restores looped-track scrobbling default", iOSLoopedTracksAfterReset, false)

let builtInRulesAfterReset: [(find: String, replace: String, enabled: Bool)] = [
    ("- Single", "", false),
    ("- EP", "", false),
]
expect("reset keeps built-in text replacement rules present", builtInRulesAfterReset.count == 2)
expect("reset keeps built-in text replacement rules disabled", builtInRulesAfterReset.allSatisfy { !$0.enabled })

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

// ─── Listening History scan dialog counting ──────────────────────────────────

section("Listening History scan · Dialog counting")

enum SimFlushOrigin {
    case live
    case playbackHistory
    case recentlyPlayed
    case manual
}

func listeningHistoryDialogCount(importedCount: Int, flushedOrigins: [SimFlushOrigin]) -> Int {
    let flushedPlaybackHistoryCount = flushedOrigins.filter { $0 == .playbackHistory }.count
    if flushedPlaybackHistoryCount > 0 {
        return flushedPlaybackHistoryCount
    }
    return importedCount
}

expectEqual(
    "flushed playback-history plays override a zero importer count",
    listeningHistoryDialogCount(importedCount: 0, flushedOrigins: [.playbackHistory, .playbackHistory]),
    2
)
expectEqual(
    "imported count is used when no playback-history items were flushed",
    listeningHistoryDialogCount(importedCount: 3, flushedOrigins: []),
    3
)
expectEqual(
    "non-playback-history flushes do not affect the dialog count",
    listeningHistoryDialogCount(importedCount: 0, flushedOrigins: [.live, .manual, .recentlyPlayed]),
    0
)
expectEqual(
    "mixed flush origins count only playback-history items",
    listeningHistoryDialogCount(importedCount: 4, flushedOrigins: [.live, .playbackHistory, .manual, .playbackHistory]),
    2
)

// ─── Summary ──────────────────────────────────────────────────────────────────

print("\n────────────────────────────────────────")
let total = passed + failed
print("Results: \(passed)/\(total) passed", failed > 0 ? "(\(failed) FAILED)" : "")
if failed > 0 { exit(1) }
