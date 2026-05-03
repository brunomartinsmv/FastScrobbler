import Foundation

enum ScrobbleSkipReason: Equatable {
    case sessionAlreadyScrobbled
    case foundInBacklog(startTimestamp: Int)
    case foundInLog(startTimestamp: Int)
    case mostRecentMatch

    func statusText(now: Date = Date()) -> String {
        switch self {
        case .sessionAlreadyScrobbled:
            return NSLocalizedString("Already scrobbled this session.", comment: "")
        case .foundInBacklog(let ts):
            let ago = agoText(ts, now: now)
            return String(format: NSLocalizedString("Skipped — already in retry queue (%@).", comment: ""), ago)
        case .foundInLog(let ts):
            let ago = agoText(ts, now: now)
            return String(format: NSLocalizedString("Skipped — already scrobbled (%@).", comment: ""), ago)
        case .mostRecentMatch:
            return NSLocalizedString("Skipped — same track was most recently scrobbled.", comment: "")
        }
    }

    private func agoText(_ timestamp: Int, now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince1970) - timestamp
        if elapsed < 60 { return NSLocalizedString("just now", comment: "") }
        let minutes = elapsed / 60
        if minutes < 60 {
            return String(format: NSLocalizedString("%dm ago", comment: ""), minutes)
        }
        let hours = minutes / 60
        return String(format: NSLocalizedString("%dh ago", comment: ""), hours)
    }
}
