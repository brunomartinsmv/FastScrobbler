import Foundation

func runICloudSyncTests() {
    section("iCloud Sync · Settings payload merge")

    enum SyncValue: Equatable {
        case bool(Bool)
        case int(Int)
    }

    struct SettingsEntry: Equatable {
        let key: String
        let value: SyncValue
        let updatedAt: Date
    }

    struct SettingsPayload: Equatable {
        let entries: [SettingsEntry]
    }

    func mergedSettings(local: SettingsPayload, remote: SettingsPayload?) -> SettingsPayload {
        guard let remote else { return local }

        var mergedByKey = Dictionary(uniqueKeysWithValues: local.entries.map { ($0.key, $0) })
        for entry in remote.entries {
            if let existing = mergedByKey[entry.key] {
                if entry.updatedAt >= existing.updatedAt {
                    mergedByKey[entry.key] = entry
                }
            } else {
                mergedByKey[entry.key] = entry
            }
        }

        return SettingsPayload(entries: mergedByKey.values.sorted { $0.key < $1.key })
    }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let older = now.addingTimeInterval(-60)
    let newer = now.addingTimeInterval(60)

    let localSettings = SettingsPayload(entries: [
        SettingsEntry(key: "iCloudSyncEnabled", value: .bool(false), updatedAt: newer),
        SettingsEntry(key: "thresholdIndex", value: .int(1), updatedAt: older),
    ])
    let remoteSettings = SettingsPayload(entries: [
        SettingsEntry(key: "iCloudSyncEnabled", value: .bool(true), updatedAt: older),
        SettingsEntry(key: "thresholdIndex", value: .int(2), updatedAt: newer),
        SettingsEntry(key: "firstArtistOnly", value: .bool(true), updatedAt: now),
    ])

    let merged = mergedSettings(local: localSettings, remote: remoteSettings)
    expectEqual("older remote iCloud-enabled flag does not override newer local value", merged.entries.first(where: { $0.key == "iCloudSyncEnabled" })?.value, .bool(false))
    expectEqual("newer remote per-key setting overrides older local value", merged.entries.first(where: { $0.key == "thresholdIndex" })?.value, .int(2))
    expectEqual("remote-only keys are preserved in merged payload", merged.entries.first(where: { $0.key == "firstArtistOnly" })?.value, .bool(true))

    section("iCloud Sync · Remote preference adoption")

    func applyRemoteEntryIfNewer(local: SettingsEntry?, remote: SettingsEntry) -> (applied: Bool, stored: SettingsEntry) {
        if let local, local.updatedAt > remote.updatedAt {
            return (false, local)
        }
        return (true, remote)
    }

    let newerRemotePreference = SettingsEntry(key: "iCloudSyncEnabled", value: .bool(true), updatedAt: newer)
    let olderRemotePreference = SettingsEntry(key: "iCloudSyncEnabled", value: .bool(true), updatedAt: older)
    let localPreference = SettingsEntry(key: "iCloudSyncEnabled", value: .bool(false), updatedAt: now)

    let appliedNewer = applyRemoteEntryIfNewer(local: localPreference, remote: newerRemotePreference)
    expect("newer remote iCloud preference is applied before startup", appliedNewer.applied)
    expectEqual("newer remote iCloud preference replaces local stored value", appliedNewer.stored.value, .bool(true))

    let ignoredOlder = applyRemoteEntryIfNewer(local: localPreference, remote: olderRemotePreference)
    expect("older remote iCloud preference is ignored", !ignoredOlder.applied)
    expectEqual("older remote iCloud preference leaves local value intact", ignoredOlder.stored.value, .bool(false))

    section("iCloud Sync · Playback-history merge")

    struct PlaybackHistoryState: Equatable {
        var lastImportAt: Date?
        var playCountByTrackID: [String: Int]
        var lastSeenPlayedAtByTrackID: [String: Date]
    }

    func maxOptionalDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (.some(left), .some(right)):
            return max(left, right)
        case (.some, .none):
            return lhs
        case (.none, .some):
            return rhs
        case (.none, .none):
            return nil
        }
    }

    func mergePlaybackHistoryState(local: PlaybackHistoryState, remote: PlaybackHistoryState?) -> PlaybackHistoryState {
        guard let remote else { return local }

        var merged = local
        merged.lastImportAt = maxOptionalDate(local.lastImportAt, remote.lastImportAt)
        for (trackID, count) in remote.playCountByTrackID {
            merged.playCountByTrackID[trackID] = max(merged.playCountByTrackID[trackID] ?? 0, count)
        }
        for (trackID, date) in remote.lastSeenPlayedAtByTrackID {
            merged.lastSeenPlayedAtByTrackID[trackID] = maxOptionalDate(merged.lastSeenPlayedAtByTrackID[trackID], date)
        }
        return merged
    }

    let localHistory = PlaybackHistoryState(
        lastImportAt: older,
        playCountByTrackID: ["a": 2, "b": 7],
        lastSeenPlayedAtByTrackID: ["a": older, "b": now]
    )
    let remoteHistory = PlaybackHistoryState(
        lastImportAt: newer,
        playCountByTrackID: ["a": 5, "c": 1],
        lastSeenPlayedAtByTrackID: ["a": newer, "c": now]
    )

    let mergedHistory = mergePlaybackHistoryState(local: localHistory, remote: remoteHistory)
    expectEqual("playback-history merge keeps the latest import date", mergedHistory.lastImportAt, newer)
    expectEqual("playback-history merge keeps the max play count for overlapping tracks", mergedHistory.playCountByTrackID["a"], 5)
    expectEqual("playback-history merge preserves local-only play counts", mergedHistory.playCountByTrackID["b"], 7)
    expectEqual("playback-history merge adds remote-only play counts", mergedHistory.playCountByTrackID["c"], 1)
    expectEqual("playback-history merge keeps the newest last-seen date per track", mergedHistory.lastSeenPlayedAtByTrackID["a"], newer)
    expectEqual("playback-history merge preserves local-only last-seen dates", mergedHistory.lastSeenPlayedAtByTrackID["b"], now)
    expectEqual("playback-history merge adds remote-only last-seen dates", mergedHistory.lastSeenPlayedAtByTrackID["c"], now)
}
