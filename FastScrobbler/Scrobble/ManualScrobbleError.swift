import Foundation

enum ManualScrobbleError: LocalizedError {
    case notAuthenticated
    case missingRequiredMetadata
    case timestampTooOld
    case timestampInFuture
    case invalidTimestamp

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return NSLocalizedString("Sign in to Last.fm before scrobbling.", comment: "")
        case .missingRequiredMetadata:
            return NSLocalizedString("Artist and song title are required.", comment: "")
        case .timestampTooOld:
            return NSLocalizedString("Last.fm rejects scrobbles older than two weeks.", comment: "")
        case .timestampInFuture:
            return NSLocalizedString("Scrobble time cannot be in the future.", comment: "")
        case .invalidTimestamp:
            return NSLocalizedString("Invalid scrobble time.", comment: "")
        }
    }
}

enum ManualScrobbleValidator {
    static func makeTrack(
        artist: String,
        title: String,
        album: String?,
        albumArtist: String?,
        timestamp: Int,
        now: Date = Date()
    ) throws -> Track {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedArtist.isEmpty, !trimmedTitle.isEmpty else {
            throw ManualScrobbleError.missingRequiredMetadata
        }
        guard timestamp > 0 else {
            throw ManualScrobbleError.invalidTimestamp
        }

        let timestampDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        guard timestampDate <= now.addingTimeInterval(60) else {
            throw ManualScrobbleError.timestampInFuture
        }
        guard timestampDate >= now.addingTimeInterval(-14 * 24 * 60 * 60) else {
            throw ManualScrobbleError.timestampTooOld
        }

        return Track(
            artist: trimmedArtist,
            title: trimmedTitle,
            album: (trimmedAlbum?.isEmpty == false) ? trimmedAlbum : nil,
            albumArtist: (trimmedAlbumArtist?.isEmpty == false) ? trimmedAlbumArtist : nil
        )
    }
}
