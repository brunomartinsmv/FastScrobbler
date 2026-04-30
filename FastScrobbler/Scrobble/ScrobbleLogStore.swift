import Foundation
import OSLog

@MainActor
final class ScrobbleLogStore: ObservableObject {
    enum Limits {
        static let maxStoredEntries = 200
        static let defaultDisplayLimit = 40
        static let manualDisplayLimit = 30
        static let maxEntryAge: TimeInterval = 45 * 24 * 60 * 60
    }

    enum Source: String, Codable, Sendable {
        case live
        case backlog
        case playbackHistory
        case recentlyPlayed
        case manual
    }

    struct Entry: Identifiable, Codable, Hashable, Sendable {
        var id: UUID
        var track: Track
        var startTimestamp: Int
        var scrobbledAt: Date
        var source: Source
        var lovedOnLastFM: Bool?
    }

    static let shared = ScrobbleLogStore()

    @Published private(set) var entries: [Entry] = []

    private let logger = Logger(subsystem: "FastScrobbler", category: "ScrobbleLogStore")

    private init() {
        load()
    }

    func recentEntries(limit: Int = Limits.defaultDisplayLimit) -> [Entry] {
        Array(entries.prefix(max(0, limit)))
    }

    func manualEntries(limit: Int = Limits.manualDisplayLimit) -> [Entry] {
        Array(entries.filter { $0.source == .manual }.prefix(max(0, limit)))
    }

    func record(
        track: Track,
        startTimestamp: Int,
        scrobbledAt: Date = Date(),
        source: Source,
        lovedOnLastFM: Bool = false
    ) {
        let entry = Entry(
            id: UUID(),
            track: track,
            startTimestamp: startTimestamp,
            scrobbledAt: scrobbledAt,
            source: source,
            lovedOnLastFM: lovedOnLastFM
        )

        if source != .playbackHistory,
           entries.contains(where: { $0.startTimestamp == startTimestamp && $0.track.dedupeKey == track.dedupeKey })
        {
            return
        }

        entries.append(entry)
        normalizeEntries(now: Date())
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func reload() {
        load()
    }

    func isMostRecentScrobble(dedupeKey: String) -> Bool {
        entries.max(by: { $0.startTimestamp < $1.startTimestamp })?.track.dedupeKey == dedupeKey
    }

    func containsSimilar(track: Track, around startTimestamp: Int, toleranceSeconds: Int) -> Bool {
        let tol = max(0, toleranceSeconds)
        return entries.contains(where: {
            $0.track.dedupeKey == track.dedupeKey && abs($0.startTimestamp - startTimestamp) <= tol
        })
    }

    func mostSimilar(track: Track, around startTimestamp: Int, toleranceSeconds: Int) -> Entry? {
        let tol = max(0, toleranceSeconds)
        return entries
            .filter { $0.track.dedupeKey == track.dedupeKey && abs($0.startTimestamp - startTimestamp) <= tol }
            .min(by: { abs($0.startTimestamp - startTimestamp) < abs($1.startTimestamp - startTimestamp) })
    }

    func containsPlaybackHistoryMatch(track: Track, playedAt: Date, endTimestampToleranceSeconds: Int) -> Bool {
        let playedAtTimestamp = Int(playedAt.timeIntervalSince1970.rounded(.down))
        let tol = max(0, endTimestampToleranceSeconds)

        return entries.contains(where: { entry in
            guard entry.track.dedupeKey == track.dedupeKey else { return false }
            let directMatch = abs(entry.startTimestamp - playedAtTimestamp) <= tol

            switch entry.source {
            case .playbackHistory, .recentlyPlayed, .manual:
                return directMatch
            case .live:
                guard let durationSeconds = playbackDurationSeconds(for: entry.track, fallbackTrack: track) else {
                    return directMatch
                }

                let expectedEndTimestamp = entry.startTimestamp + durationSeconds
                return abs(expectedEndTimestamp - playedAtTimestamp) <= tol
            case .backlog:
                guard let durationSeconds = playbackDurationSeconds(for: entry.track, fallbackTrack: track) else {
                    return directMatch
                }

                let expectedEndTimestamp = entry.startTimestamp + durationSeconds
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
    ) -> Int {
        let playedAtTimestamp = Int(playedAt.timeIntervalSince1970.rounded(.down))
        let exactTol = max(0, exactTimestampToleranceSeconds)
        let endTol = max(0, endTimestampToleranceSeconds)

        return entries.filter { entry in
            matchesPlaybackHistoryImport(
                entry: entry,
                track: track,
                startTimestamp: startTimestamp,
                playedAtTimestamp: playedAtTimestamp,
                exactTimestampToleranceSeconds: exactTol,
                endTimestampToleranceSeconds: endTol
            )
        }.count
    }

    private func load() {
        let legacyURL = legacyFileURL()
        let sharedURL = sharedFileURL()

        func readEntries(from url: URL) -> [Entry] {
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([Entry].self, from: data)
            } catch {
                return []
            }
        }

        if let sharedURL {
            let sharedEntries = readEntries(from: sharedURL)
            let legacyEntries = readEntries(from: legacyURL)

            var map: [String: Entry] = [:]
            for e in sharedEntries {
                map[mergeIdentity(for: e)] = e
            }
            for e in legacyEntries {
                let key = mergeIdentity(for: e)
                if let existing = map[key] {
                    if e.scrobbledAt > existing.scrobbledAt {
                        map[key] = e
                    }
                } else {
                    map[key] = e
                }
            }

            entries = normalizedEntries(Array(map.values), now: Date())

            // Persist into the shared container so app + extensions share the same dedupe history.
            do {
                try persist(entries, preferredURL: sharedURL, fallbackURL: legacyURL)
            } catch {
                logger.warning("failed to persist merged scrobble log: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            entries = normalizedEntries(readEntries(from: legacyURL), now: Date())
        }
    }

    private func save() {
        normalizeEntries(now: Date())
        do {
            try persist(entries, preferredURL: sharedFileURL(), fallbackURL: legacyFileURL())
        } catch {
            logger.warning("failed to persist scrobble log: \(error.localizedDescription, privacy: .public)")
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

    private func normalizeEntries(now: Date) {
        entries = normalizedEntries(entries, now: now)
    }

    private func normalizedEntries(_ entries: [Entry], now: Date) -> [Entry] {
        let cutoff = now.addingTimeInterval(-Limits.maxEntryAge)
        var normalized = entries.filter { $0.scrobbledAt >= cutoff }
        normalized.sort {
            if $0.scrobbledAt == $1.scrobbledAt {
                return $0.startTimestamp > $1.startTimestamp
            }
            return $0.scrobbledAt > $1.scrobbledAt
        }
        if normalized.count > Limits.maxStoredEntries {
            normalized.removeLast(normalized.count - Limits.maxStoredEntries)
        }
        return normalized
    }

    private func mergeIdentity(for entry: Entry) -> String {
        "\(entry.source.rawValue)|\(entry.track.dedupeKey)|\(entry.startTimestamp)"
    }

    private func matchesPlaybackHistoryImport(
        entry: Entry,
        track: Track,
        startTimestamp: Int,
        playedAtTimestamp: Int,
        exactTimestampToleranceSeconds: Int,
        endTimestampToleranceSeconds: Int
    ) -> Bool {
        guard entry.track.dedupeKey == track.dedupeKey else { return false }

        let exactMatch = abs(entry.startTimestamp - startTimestamp) <= exactTimestampToleranceSeconds
        let directPlayedAtMatch = abs(entry.startTimestamp - playedAtTimestamp) <= endTimestampToleranceSeconds

        switch entry.source {
        case .playbackHistory, .recentlyPlayed, .manual:
            return exactMatch || directPlayedAtMatch
        case .live:
            guard let durationSeconds = playbackDurationSeconds(for: entry.track, fallbackTrack: track) else {
                return exactMatch || directPlayedAtMatch
            }

            let expectedEndTimestamp = entry.startTimestamp + durationSeconds
            return exactMatch || abs(expectedEndTimestamp - playedAtTimestamp) <= endTimestampToleranceSeconds
        case .backlog:
            guard let durationSeconds = playbackDurationSeconds(for: entry.track, fallbackTrack: track) else {
                return exactMatch || directPlayedAtMatch
            }

            let expectedEndTimestamp = entry.startTimestamp + durationSeconds
            return exactMatch ||
                directPlayedAtMatch ||
                abs(expectedEndTimestamp - playedAtTimestamp) <= endTimestampToleranceSeconds
        }
    }

    private func fileURL() -> URL {
        sharedFileURL() ?? legacyFileURL()
    }

    private func sharedFileURL() -> URL? {
        AppGroup.sharedDataDirectoryURL()?
            .appendingPathComponent("scrobble_log.json")
    }

    private func legacyFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? {
            logger.warning("applicationSupportDirectory unavailable; falling back to temporaryDirectory")
            return FileManager.default.temporaryDirectory
        }()
        let bundleID = Bundle.main.bundleIdentifier ?? "FastScrobbler"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("scrobble_log.json")
    }

    private func persist(_ entries: [Entry], preferredURL: URL?, fallbackURL: URL) throws {
        let data = try JSONEncoder().encode(entries)

        if let preferredURL {
            do {
                try write(data, to: preferredURL)
                return
            } catch {
                logger.warning("shared scrobble log write failed; falling back to Application Support: \(error.localizedDescription, privacy: .public)")
            }
        }

        try write(data, to: fallbackURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: url, options: [.atomic])
    }
}
