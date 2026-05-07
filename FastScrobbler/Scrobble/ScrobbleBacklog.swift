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

    struct CleanupResult: Sendable, Equatable {
        var removedTooOldCount: Int
        var removedTooManyFailedAttemptsCount: Int
        var removedTooManyItemsCount: Int
        var remainingCount: Int

        var removedCount: Int {
            removedTooOldCount + removedTooManyFailedAttemptsCount + removedTooManyItemsCount
        }
    }

    static let shared = ScrobbleBacklog()

    private enum CleanupLimits {
        static let maxPendingItems = 1_000
        static let maxItemAge: TimeInterval = 14 * 24 * 60 * 60
        static let maxAttemptCount = 10
    }

    private struct PersistedTrack: Codable {
        var artist: String
        var title: String
        var album: String?
        var albumArtist: String?
        var durationSeconds: TimeInterval?
        var usesFallbackDuration: Bool?
        var persistentID: UInt64?
        var playbackStoreID: String?
        var isCompilation: Bool?

        private enum CodingKeys: String, CodingKey {
            case artist = "a"
            case title = "t"
            case album = "al"
            case albumArtist = "aa"
            case durationSeconds = "d"
            case usesFallbackDuration = "uf"
            case persistentID = "p"
            case playbackStoreID = "ps"
            case isCompilation = "ic"
        }

        init(track: Track) {
            artist = track.artist
            title = track.title
            album = track.album
            albumArtist = track.albumArtist
            durationSeconds = track.durationSeconds
            usesFallbackDuration = track.usesFallbackDuration
            persistentID = track.persistentID
            playbackStoreID = track.playbackStoreID
            isCompilation = track.isCompilation
        }

        var track: Track {
            Track(
                artist: artist,
                title: title,
                album: album,
                albumArtist: albumArtist,
                durationSeconds: durationSeconds,
                usesFallbackDuration: usesFallbackDuration,
                persistentID: persistentID,
                playbackStoreID: playbackStoreID,
                isCompilation: isCompilation
            )
        }
    }

    private struct PersistedItem: Codable {
        var id: UUID
        var track: PersistedTrack
        var startTimestamp: Int
        var origin: Origin?
        var wasAppleMusicFavorite: Bool?
        var queuedAt: Date
        var attemptCount: Int
        var lastAttemptAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id = "i"
            case track = "t"
            case startTimestamp = "s"
            case origin = "o"
            case wasAppleMusicFavorite = "f"
            case queuedAt = "q"
            case attemptCount = "a"
            case lastAttemptAt = "l"
        }

        init(item: Item) {
            id = item.id
            track = PersistedTrack(track: item.track)
            startTimestamp = item.startTimestamp
            origin = item.origin
            wasAppleMusicFavorite = item.wasAppleMusicFavorite
            queuedAt = item.queuedAt
            attemptCount = item.attemptCount
            lastAttemptAt = item.lastAttemptAt
        }

        var item: Item {
            Item(
                id: id,
                track: track.track,
                startTimestamp: startTimestamp,
                origin: origin,
                wasAppleMusicFavorite: wasAppleMusicFavorite,
                queuedAt: queuedAt,
                attemptCount: attemptCount,
                lastAttemptAt: lastAttemptAt
            )
        }
    }

    private let logger = Logger(subsystem: "FastScrobbler", category: "ScrobbleBacklog")
    private var isLoaded = false
    private var isFlushing = false
    private var items: [Item] = []

    private init() {}

    func pendingCount() async -> Int {
        await loadIfNeeded()
        return items.count
    }

    func storageSizeBytes() async -> Int64 {
        let urls = [sharedFileURL(), legacyFileURL()].compactMap { $0 }
        var seenPaths = Set<String>()
        var total: Int64 = 0

        for url in urls {
            guard seenPaths.insert(url.path).inserted else { continue }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                continue
            }
            total += size.int64Value
        }

        return total
    }

    @discardableResult
    func cleanupNow() async -> CleanupResult {
        await loadIfNeeded()
        let result = pruneItems(now: Date())
        if result.removedCount > 0 {
            logCleanup(result)
        }
        await save(pruneBeforeWrite: false)
        return result
    }

    func clearAll() async {
        await loadIfNeeded()
        guard !items.isEmpty else {
            await save(pruneBeforeWrite: false)
            return
        }
        items = []
        await save(pruneBeforeWrite: false)
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
        _ = pruneItems(now: Date())

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
                    if let clientError = error as? LastFMClient.ClientError,
                       !clientError.shouldRetryScrobble {
                        logger.warning("discarding non-retryable backlog item: \(error.localizedDescription, privacy: .public)")
                        if idx < items.count, items[idx].id == item.id {
                            items.remove(at: idx)
                        } else if let currentIndex = items.firstIndex(where: { $0.id == item.id }) {
                            items.remove(at: currentIndex)
                        }
                    } else {
                        item.attemptCount += 1
                        item.lastAttemptAt = now
                        if idx < items.count, items[idx].id == item.id {
                            items[idx] = item
                        } else if let currentIndex = items.firstIndex(where: { $0.id == item.id }) {
                            items[currentIndex] = item
                        } else {
                            // Item was already removed (or the backlog was mutated unexpectedly while awaiting).
                        }
                        idx += 1
                    }
                    logger.warning("backlog scrobble failed: \(error.localizedDescription, privacy: .public)")
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
            items = try decodeItems(from: data)
        } catch {
            items = []
        }

        let result = pruneItems(now: Date())
        if result.removedCount > 0 {
            logCleanup(result)
            await save(pruneBeforeWrite: false)
        }
    }

    private func save(pruneBeforeWrite: Bool = true) async {
        let url = fileURL()
        do {
            if pruneBeforeWrite {
                let result = pruneItems(now: Date())
                if result.removedCount > 0 {
                    logCleanup(result)
                }
            }
            let data = try JSONEncoder().encode(items.map(PersistedItem.init))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: url, options: [.atomic])
            deleteLegacyFileIfRedundant()
        } catch {
            logger.warning("failed to persist backlog: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pruneItems(now: Date) -> CleanupResult {
        let originalCount = items.count
        let cutoffTimestamp = Int(now.addingTimeInterval(-CleanupLimits.maxItemAge).timeIntervalSince1970.rounded(.down))

        items.removeAll { item in
            item.attemptCount >= CleanupLimits.maxAttemptCount
        }
        let removedTooManyFailedAttemptsCount = originalCount - items.count

        let countAfterFailedAttemptPrune = items.count
        items.removeAll { item in
            item.startTimestamp > 0 && item.startTimestamp < cutoffTimestamp
        }
        let removedTooOldCount = countAfterFailedAttemptPrune - items.count

        var removedTooManyItemsCount = 0
        if items.count > CleanupLimits.maxPendingItems {
            items.sort {
                if $0.startTimestamp == $1.startTimestamp {
                    return $0.queuedAt > $1.queuedAt
                }
                return $0.startTimestamp > $1.startTimestamp
            }
            removedTooManyItemsCount = items.count - CleanupLimits.maxPendingItems
            items.removeLast(removedTooManyItemsCount)
        }

        return CleanupResult(
            removedTooOldCount: removedTooOldCount,
            removedTooManyFailedAttemptsCount: removedTooManyFailedAttemptsCount,
            removedTooManyItemsCount: removedTooManyItemsCount,
            remainingCount: items.count
        )
    }

    private func logCleanup(_ result: CleanupResult) {
        logger.info(
            """
            cleaned scrobble backlog: old=\(result.removedTooOldCount, privacy: .public), \
            failed=\(result.removedTooManyFailedAttemptsCount, privacy: .public), \
            excess=\(result.removedTooManyItemsCount, privacy: .public), \
            remaining=\(result.remainingCount, privacy: .public)
            """
        )
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

    private func decodeItems(from data: Data) throws -> [Item] {
        if let persisted = try? JSONDecoder().decode([PersistedItem].self, from: data) {
            return persisted.map(\.item)
        }
        return try JSONDecoder().decode([Item].self, from: data)
    }

    private func deleteLegacyFileIfRedundant() {
        guard let sharedURL = sharedFileURL() else { return }
        let legacyURL = legacyFileURL()
        guard sharedURL.path != legacyURL.path else { return }
        guard FileManager.default.fileExists(atPath: sharedURL.path) else { return }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
