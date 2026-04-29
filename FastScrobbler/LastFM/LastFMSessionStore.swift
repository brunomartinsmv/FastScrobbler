import Foundation

enum LastFMSessionStore {
    private static let sessionKeyDefaultsKey = "FastScrobbler.lastfm.sessionKey"

    static func readSessionKey() -> String? {
        let value = AppGroup.userDefaults.string(forKey: sessionKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func writeSessionKey(_ sessionKey: String) {
        AppGroup.userDefaults.set(sessionKey, forKey: sessionKeyDefaultsKey)
    }

    static func deleteSessionKey() {
        AppGroup.userDefaults.removeObject(forKey: sessionKeyDefaultsKey)
    }
}
