import Foundation

func runManualScrobbleTests() {
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
}
