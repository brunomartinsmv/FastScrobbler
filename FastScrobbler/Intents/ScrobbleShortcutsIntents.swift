import AppIntents
import Foundation
import MediaPlayer
import OSLog

extension Notification.Name {
    static let openManualScrobble = Notification.Name("FastScrobbler.openManualScrobble")
    static let triggerPendingScan = Notification.Name("FastScrobbler.triggerPendingScan")
    static let triggerScrobbleSong = Notification.Name("FastScrobbler.triggerScrobbleSong")
}

enum ShortcutsIntentError: Error, LocalizedError {
    case notConnected
    case mediaLibraryDenied
    case noNowPlaying
    case invalidNowPlayingMetadata

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return NSLocalizedString("Connect Last.fm to scrobble.", comment: "")
        case .mediaLibraryDenied:
            return NSLocalizedString("Media Library access is required to read now-playing metadata.", comment: "")
        case .noNowPlaying:
            return NSLocalizedString("No now-playing track.", comment: "")
        case .invalidNowPlayingMetadata:
            return NSLocalizedString("Now-playing track metadata was incomplete.", comment: "")
        }
    }
}

private enum ShortcutsPlaybackReader {
    static func nowPlayingTrackAndPlaybackTime() throws -> (track: Track, playbackTimeSeconds: TimeInterval) {
        let player = MPMusicPlayerController.systemMusicPlayer
        if MPMediaLibrary.authorizationStatus() == .authorized, let item = player.nowPlayingItem {
            let artist = (item.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else {
                throw ShortcutsIntentError.invalidNowPlayingMetadata
            }

            let album = item.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let albumArtist = item.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCompilation = item.isCompilation
            let duration = item.playbackDuration
            let pid = item.persistentID
            let playbackStoreID = item.playbackStoreID

            let track = Track(
                artist: artist,
                title: title,
                album: (album?.isEmpty == false) ? album : nil,
                albumArtist: (albumArtist?.isEmpty == false) ? albumArtist : nil,
                durationSeconds: duration > 0 ? duration : nil,
                persistentID: pid,
                playbackStoreID: playbackStoreID.isEmpty ? nil : playbackStoreID,
                isCompilation: isCompilation
            )

            return (track: track, playbackTimeSeconds: max(0, player.currentPlaybackTime))
        }

        if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            let artist = ((info[MPMediaItemPropertyArtist] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = ((info[MPMediaItemPropertyTitle] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else {
                throw ShortcutsIntentError.invalidNowPlayingMetadata
            }

            let album = (info[MPMediaItemPropertyAlbumTitle] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let albumArtist = (info[MPMediaItemPropertyAlbumArtist] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let duration: TimeInterval? = {
                if let n = info[MPMediaItemPropertyPlaybackDuration] as? NSNumber { return n.doubleValue }
                if let d = info[MPMediaItemPropertyPlaybackDuration] as? Double { return d }
                return nil
            }()
            let elapsed: TimeInterval = {
                if let n = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber { return n.doubleValue }
                if let d = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double { return d }
                return 0
            }()
            let pid: UInt64? = {
                if let n = info[MPMediaItemPropertyPersistentID] as? NSNumber { return n.uint64Value }
                if let u = info[MPMediaItemPropertyPersistentID] as? UInt64 { return u }
                return nil
            }()
            let isCompilation: Bool? = {
                if let n = info[MPMediaItemPropertyIsCompilation] as? NSNumber { return n.boolValue }
                if let b = info[MPMediaItemPropertyIsCompilation] as? Bool { return b }
                return nil
            }()

            let track = Track(
                artist: artist,
                title: title,
                album: (album?.isEmpty == false) ? album : nil,
                albumArtist: (albumArtist?.isEmpty == false) ? albumArtist : nil,
                durationSeconds: (duration ?? 0) > 0 ? duration : nil,
                persistentID: pid,
                playbackStoreID: nil,
                isCompilation: isCompilation
            )
            return (track: track, playbackTimeSeconds: max(0, elapsed))
        }

        if MPMediaLibrary.authorizationStatus() != .authorized {
            throw ShortcutsIntentError.mediaLibraryDenied
        }
        throw ShortcutsIntentError.noNowPlaying
    }
}

struct OpenManualScrobbleIntent: AppIntent {
    static let title: LocalizedStringResource = "Manual Scrobble"
    static let description = IntentDescription("Opens the Manual Scrobble screen in FastScrobbler.")
    static let openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openManualScrobble, object: nil)
        }
        return .result()
    }
}

enum ListeningHistoryReviewLaunchTarget: String, AppEnum {
    case reviewList

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Listening History Review")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .reviewList: DisplayRepresentation("Review List")
    ]
}

struct OpenListeningHistoryReviewIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Listening History Review"
    static let description = IntentDescription("Opens the Listening History review list in FastScrobbler.")

    @Parameter(title: "Target")
    var target: ListeningHistoryReviewLaunchTarget

    init() {
        target = .reviewList
    }

    init(target: ListeningHistoryReviewLaunchTarget) {
        self.target = target
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppSettings.requestOpeningListeningHistoryReview()
        ControlWidgetStatusStore.markSuccess(.scanListeningHistory, duration: 1)
        return .result(
            dialog: IntentDialog(
                stringLiteral: NSLocalizedString(
                    "Opening the Listening History review list in FastScrobbler.",
                    comment: ""
                )
            )
        )
    }
}

struct SendNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Now Playing"
    static let description = IntentDescription("Sends the currently playing track to Last.fm as \"Now Playing\".")
    static let openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let logger = Logger(subsystem: "FastScrobbler", category: "SendNowPlayingIntent")

        guard let sessionKey = LastFMSessionStore.readSessionKey() else {
            throw ShortcutsIntentError.notConnected
        }

        let track = try ShortcutsPlaybackReader.nowPlayingTrackAndPlaybackTime().track
        let trackToSend = track.applyingProScrobblePreferences()
        let client = try LastFMClient()

        do {
            try await client.updateNowPlaying(track: trackToSend, sessionKey: sessionKey)
            return .result(
                dialog: IntentDialog(
                    stringLiteral: String.localizedStringWithFormat(
                        NSLocalizedString("Sent now playing: %@ — %@", comment: ""),
                        trackToSend.artist,
                        trackToSend.title
                    )
                )
            )
        } catch {
            logger.warning("updateNowPlaying failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

struct ScrobbleSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Scrobble Song"
    static let description = IntentDescription("Scrobbles the currently playing track to Last.fm.")
    static let openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let logger = Logger(subsystem: "FastScrobbler", category: "ScrobbleSongIntent")

        guard let sessionKey = LastFMSessionStore.readSessionKey() else {
            throw ShortcutsIntentError.notConnected
        }

        let now = Date()
        let (track, _) = try ShortcutsPlaybackReader.nowPlayingTrackAndPlaybackTime()
        let scrobbleTrack = track.applyingProScrobblePreferences()
        let ts = max(1, Int(now.timeIntervalSince1970.rounded(.down)))

        let client = try LastFMClient()
        do {
            try await client.scrobble(track: scrobbleTrack, sessionKey: sessionKey, startTimestamp: ts)
            await MainActor.run {
                ScrobbleLogStore.shared.record(track: scrobbleTrack, startTimestamp: ts, source: .live)
            }
            return .result(
                dialog: IntentDialog(
                    stringLiteral: String.localizedStringWithFormat(
                        NSLocalizedString("Scrobbled: %@ — %@", comment: ""),
                        scrobbleTrack.artist,
                        scrobbleTrack.title
                    )
                )
            )
        } catch {
            logger.warning("manual scrobble failed: \(error.localizedDescription, privacy: .public)")
            if (error as? LastFMClient.ClientError)?.shouldRetryScrobble ?? true {
                await ScrobbleBacklog.shared.enqueue(track: scrobbleTrack, startTimestamp: ts)
            }
            throw error
        }
    }
}

struct ScanListeningHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan History"
    static let description = IntentDescription("Scans Listening History for missed scrobbles.")
    static let openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        guard LastFMSessionStore.readSessionKey() != nil else {
            throw ShortcutsIntentError.notConnected
        }

        ControlWidgetStatusStore.markInProgress(.scanListeningHistory)
        let request: AppSettings.PendingListeningHistoryLaunchRequest =
            AppSettings.listeningHistoryRequireConfirmationEnabled() ? .scanAndOpenReview : .scanAndShowResult
        AppSettings.requestPendingListeningHistoryLaunch(request)
        ControlWidgetStatusStore.markSuccess(.scanListeningHistory, duration: 1)
        return .result()
    }
}

@available(iOS 16.0, *)
struct FastScrobblerShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .purple

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScrobbleSongIntent(),
            phrases: [
                "Scrobble song in \(.applicationName)",
                "Scrobble now in \(.applicationName)",
                "Scrobble this track in \(.applicationName)",
            ],
            shortTitle: "Scrobble Song",
            systemImageName: "arrow.triangle.2.circlepath"
        )

        AppShortcut(
            intent: SendNowPlayingIntent(),
            phrases: [
                "Send now playing in \(.applicationName)",
                "Update now playing in \(.applicationName)",
            ],
            shortTitle: "Send Now Playing",
            systemImageName: "music.note"
        )

        AppShortcut(
            intent: OpenManualScrobbleIntent(),
            phrases: [
                "Manual scrobble in \(.applicationName)",
                "Open manual scrobble in \(.applicationName)",
            ],
            shortTitle: "Manual Scrobble",
            systemImageName: "plus.circle"
        )

        AppShortcut(
            intent: ScanListeningHistoryIntent(),
            phrases: [
                "Scan listening history in \(.applicationName)",
                "Scan history in \(.applicationName)",
            ],
            shortTitle: "Scan History",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
