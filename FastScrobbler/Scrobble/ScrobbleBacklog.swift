import Foundation
import OSLog

actor ScrobbleBacklog {
    enum Origin: String, Codable, Sendable {
        case live
        case playbackHistory
        case recentlyPlayed
        case manual
    }

    struct Item: Codable, Hashable {
        var id: UUID
        var track: Track
        var startTimestamp: Int
        var origin: Origin?
        var wasAppleMusicFavorite: Bool?
        var queuedAt: Date
        var attemptCount: Int
        var lastAttemptAt: Date?
    }

    struct FlushResult: Sendable {
        struct SentItem: Sendable, Hashable {
            var track: Track
            var startTimestamp: Int
            var scrobbledAt: Date
            var origin: Origin?
            var lovedOnLastFM: Bool
        }

        var sentCount: Int
        var skippedCount: Int
        var remainingCount: Int
        var sentItems: [SentItem]
    }

    static let shared = ScrobbleBacklog()

    private let logger = Logger(subsystem: "FastScrobbler", category: "ScrobbleBacklog")
    private var isLoaded = false
    private var isFlushing = false
    private var items: [Item] = []

    private init() {}

    func pendingCount() async -> Int {
        await loadIfNeeded()
        return items.count
    }

    func enqueue(track: Track, startTimestamp: Int) async {
        await enqueue(track: track, startTimestamp: startTimestamp, origin: nil)
    }

    func enqueue(track: Track, startTimestamp: Int, origin: Origin?) async {
        await enqueue(track: track, startTimestamp: startTimestamp, origin: origin, wasAppleMusicFavorite: nil)
    }

    func enqueue(track: Track, startTimestamp: Int, origin: Origin?, wasAppleMusicFavorite: Bool?) async {
        await enqueue(
            track: track,
            startTimestamp: startTimestamp,
            origin: origin,
            wasAppleMusicFavorite: wasAppleMusicFavorite,
            allowExactDuplicates: false
        )
    }

    func enqueue(
        track: Track,
        startTimestamp: Int,
        origin: Origin?,
        wasAppleMusicFavorite: Bool?,
        allowExactDuplicates: Bool
    ) async {
        await loadIfNeeded()

        let allowsOriginExactDuplicates = origin == .playbackHistory

        if !allowExactDuplicates,
           !allowsOriginExactDuplicates,
           items.contains(where: { $0.startTimestamp == startTimestamp && $0.track.dedupeKey == track.dedupeKey })
        {
            return
        }

        items.append(
            Item(
                id: UUID(),
                track: track,
                startTimestamp: startTimestamp,
                origin: origin,
                wasAppleMusicFavorite: wasAppleMusicFavorite,
                queuedAt: Date(),
                attemptCount: 0,
                lastAttemptAt: nil
            )
        )
        await save()
    }

    func isMostRecentScrobble(dedupeKey: String) async -> Bool {
        await loadIfNeeded()
        return items.max(by: { $0.startTimestamp < $1.startTimestamp })?.track.dedupeKey == dedupeKey
    }

    func containsSimilar(track: Track, around startTimestamp: Int, toleranceSeconds: Int) async -> Bool {
        await loadIfNeeded()
        let tol = max(0, toleranceSeconds)
        return items.contains(where: {
            $0.track.dedupeKey == track.dedupeKey && abs($0.startTimestamp - startTimestamp) <= tol
        })
    }

    func mostSimilar(track: Track, around startTimestamp: Int, toleranceSeconds: Int) async -> Item? {
        await loadIfNeeded()
        let tol = max(0, toleranceSeconds)
        return items
            .filter { $0.track.dedupeKey == track.dedupeKey && abs($0.startTimestamp - startTimestamp) <= tol }
            .min(by: { abs($0.startTimestamp - startTimestamp) < abs($1.startTimestamp - startTimestamp) })
    }

    func containsPlaybackHistoryMatch(track: Track, playedAt: Date, endTimestampToleranceSeconds: Int) async -> Bool {
        await loadIfNeeded()
        let playedAtTimestamp = Int(playedAt.timeIntervalSince1970.rounded(.down))
        let tol = max(0, endTimestampToleranceSeconds)

        return items.contains(where: { item in
            guard item.track.dedupeKey == track.dedupeKey else { return false }
            let directMatch = abs(item.startTimestamp - playedAtTimestamp) <= tol

            switch item.origin {
            case .playbackHistory, .recentlyPlayed, .manual:
                return directMatch
            case .live:
                guard let durationSeconds = playbackDurationSeconds(for: item.track, fallbackTrack: track) else {
                    return directMatch
                }

                let expectedEndTimestamp = item.startTimestamp + durationSeconds
                return abs(expectedEndTimestamp - playedAtTimestamp) <= tol
            case .none:
                guard let durationSeconds = playbackDurationSeconds(for: item.track, fallbackTrack: track) else {
                    return directMatch
                }

                let expectedEndTimestamp = item.startTimestamp + durationSeconds
                return directMatch || abs(expectedEndTimestamp - playedAtTimestamp) <= tol
            }
        })
    }

    func playbackHistoryImportMatchCount(
        track: Track,
        startTimestamp: Int,
        playedAt: Date,
        exactTimestampToleranceSeconds: Int,
        endTimestampToleranceSeconds: Int
    ) async -> Int {
        await loadIfNeeded()
        let playedAtTimestamp = Int(playedAt.timeIntervalSince1970.rounded(.down))
        let exactTol = max(0, exactTimestampToleranceSeconds)
        let endTol = max(0, endTimestampToleranceSeconds)

        return items.filter { item in
            matchesPlaybackHistoryImport(
                item: item,
                track: track,
                startTimestamp: startTimestamp,
                playedAtTimestamp: playedAtTimestamp,
                exactTimestampToleranceSeconds: exactTol,
                endTimestampToleranceSeconds: endTol
            )
        }.count
    }

    @discardableResult
    func removeAll(origin targetOrigin: Origin) async -> Int {
        await loadIfNeeded()

        let originalCount = items.count
        items.removeAll { $0.origin == targetOrigin }
        let removedCount = originalCount - items.count

        if removedCount > 0 {
            await save()
        }

        return removedCount
    }

    func flush(sessionKey: String, maxItems: Int = 25) async -> FlushResult {
        await flush(sessionKey: sessionKey, maxItems: maxItems, ignoreBackoff: false)
    }

    func flush(sessionKey: String, maxItems: Int = 25, ignoreBackoff: Bool) async -> FlushResult {
        await loadIfNeeded()
        guard !isFlushing else {
            logger.debug("flush skipped (already in progress)")
            return FlushResult(sentCount: 0, skippedCount: 0, remainingCount: items.count, sentItems: [])
        }
        guard !items.isEmpty else {
            return FlushResult(sentCount: 0, skippedCount: 0, remainingCount: 0, sentItems: [])
        }

        isFlushing = true
        defer { isFlushing = false }

        let loveOnFavoriteEnabled = ProSettings.loveOnFavoriteEnabled()

        let now = Date()
        var sentCount = 0
        var skippedCount = 0
        var sentItems: [FlushResult.SentItem] = []

        do {
            let client = try LastFMClient()

            items.sort(by: { $0.startTimestamp < $1.startTimestamp })
            var idx = 0
            while idx < items.count, sentCount < maxItems {
                var item = items[idx]

                if item.startTimestamp <= 0 || item.attemptCount >= 10 {
                    logger.warning("discarding backlog item after \(item.attemptCount, privacy: .public) attempts: \(item.track.artist, privacy: .public) – \(item.track.title, privacy: .public)")
                    items.remove(at: idx)
                    continue
                }

                if !ignoreBackoff, let last = item.lastAttemptAt {
                    // Exponential backoff: 1 min, 2 min, 4 min … up to 60 min, plus ±30s jitter.
                    let baseDelay = min(TimeInterval(60 * (1 << min(item.attemptCount - 1, 6))), 60 * 60)
                    let jitter = TimeInterval(Int.random(in: -30...30))
                    if now.timeIntervalSince(last) < baseDelay + jitter {
                        skippedCount += 1
                        idx += 1
                        continue
                    }
                }

                do {
                    try await client.scrobble(track: item.track, sessionKey: sessionKey, startTimestamp: item.startTimestamp)
                    var lovedOnLastFM = false
                    if item.wasAppleMusicFavorite == true, loveOnFavoriteEnabled {
                        do {
                            try await client.love(track: item.track, sessionKey: sessionKey)
                            lovedOnLastFM = true
                        } catch {
                            // Keep silent; scrobble succeeded even if loving fails.
                        }
                    }
                    sentItems.append(
                        FlushResult.SentItem(
                            track: item.track,
                            startTimestamp: item.startTimestamp,
                            scrobbledAt: now,
                            origin: item.origin,
                            lovedOnLastFM: lovedOnLastFM
                        )
                    )
                    if idx < items.count, items[idx].id == item.id {
                        items.remove(at: idx)
                    } else if let currentIndex = items.firstIndex(where: { $0.id == item.id }) {
                        items.remove(at: currentIndex)
                    } else {
                        // Item was already removed (or the backlog was mutated unexpectedly while awaiting).
                    }
                    sentCount += 1
                } catch {
                    item.attemptCount += 1
                    item.lastAttemptAt = now
                    if idx < items.count, items[idx].id == item.id {
                        items[idx] = item
                    } else if let currentIndex = items.firstIndex(where: { $0.id == item.id }) {
                        items[currentIndex] = item
                    } else {
                        // Item was already removed (or the backlog was mutated unexpectedly while awaiting).
                    }
                    logger.warning("backlog scrobble failed: \(error.localizedDescription, privacy: .public)")
                    idx += 1
                }
            }
        } catch {
            logger.warning("failed to init LastFMClient for backlog flush: \(error.localizedDescription, privacy: .public)")
        }

        await save()
        return FlushResult(sentCount: sentCount, skippedCount: skippedCount, remainingCount: items.count, sentItems: sentItems)
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true

        if let sharedURL = sharedFileURL() {
            let fm = FileManager.default
            if !fm.fileExists(atPath: sharedURL.path) {
                let legacyURL = legacyFileURL()
                if fm.fileExists(atPath: legacyURL.path) {
                    do {
                        try fm.createDirectory(at: sharedURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                        try fm.moveItem(at: legacyURL, to: sharedURL)
                    } catch {
                        logger.warning("failed to migrate backlog to app group: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        let url = fileURL()
        do {
            let data = try Data(contentsOf: url)
            items = try JSONDecoder().decode([Item].self, from: data)
        } catch {
            items = []
        }
    }

    private func save() async {
        let url = fileURL()
        do {
            let data = try JSONEncoder().encode(items)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            logger.warning("failed to persist backlog: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func playbackDurationSeconds(for storedTrack: Track, fallbackTrack: Track) -> Int? {
        let candidates = [storedTrack.durationSeconds, fallbackTrack.durationSeconds]
        for candidate in candidates {
            guard let candidate, candidate > 0 else { continue }
            return Int(candidate.rounded(.down))
        }
        return nil
    }

    private func fileURL() -> URL {
        sharedFileURL() ?? legacyFileURL()
    }

    private func matchesPlaybackHistoryImport(
        item: Item,
        track: Track,
        startTimestamp: Int,
        playedAtTimestamp: Int,
        exactTimestampToleranceSeconds: Int,
        endTimestampToleranceSeconds: Int
    ) -> Bool {
        guard item.track.dedupeKey == track.dedupeKey else { return false }

        let exactMatch = abs(item.startTimestamp - startTimestamp) <= exactTimestampToleranceSeconds
        let directPlayedAtMatch = abs(item.startTimestamp - playedAtTimestamp) <= endTimestampToleranceSeconds

        switch item.origin {
        case .playbackHistory, .recentlyPlayed, .manual:
            return exactMatch || directPlayedAtMatch
        case .live:
            guard let durationSeconds = playbackDurationSeconds(for: item.track, fallbackTrack: track) else {
                return exactMatch || directPlayedAtMatch
            }

            let expectedEndTimestamp = item.startTimestamp + durationSeconds
            return exactMatch || abs(expectedEndTimestamp - playedAtTimestamp) <= endTimestampToleranceSeconds
        case .none:
            guard let durationSeconds = playbackDurationSeconds(for: item.track, fallbackTrack: track) else {
                return exactMatch || directPlayedAtMatch
            }

            let expectedEndTimestamp = item.startTimestamp + durationSeconds
            return exactMatch ||
                directPlayedAtMatch ||
                abs(expectedEndTimestamp - playedAtTimestamp) <= endTimestampToleranceSeconds
        }
    }

    private func sharedFileURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.kevin.FastScrobbler")?
            .appendingPathComponent("FastScrobblerShared", isDirectory: true)
            .appendingPathComponent("scrobble_backlog.json")
    }

    private func legacyFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? {
            logger.warning("applicationSupportDirectory unavailable; falling back to temporaryDirectory")
            return FileManager.default.temporaryDirectory
        }()
        let bundleID = Bundle.main.bundleIdentifier ?? "FastScrobbler"
        return base.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("scrobble_backlog.json")
    }
}
