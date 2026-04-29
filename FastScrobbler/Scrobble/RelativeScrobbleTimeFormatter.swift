import Foundation

enum RelativeScrobbleTimeFormatter {
    static func string(from date: Date, to now: Date) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        let totalMinutes = Int(delta / 60)

        if totalMinutes < 60 {
            return String.localizedStringWithFormat(NSLocalizedString("%lldm ago", comment: ""), Int64(totalMinutes))
        }

        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            let minutes = totalMinutes % 60
            if minutes == 0 {
                return String.localizedStringWithFormat(NSLocalizedString("%lldh ago", comment: ""), Int64(totalHours))
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("%1$lldh %2$lldm ago", comment: ""),
                Int64(totalHours),
                Int64(minutes)
            )
        }

        let days = totalHours / 24
        let hours = totalHours % 24
        if hours == 0 {
            return String.localizedStringWithFormat(NSLocalizedString("%lldd ago", comment: ""), Int64(days))
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("%1$lldd %2$lldh ago", comment: ""),
            Int64(days),
            Int64(hours)
        )
    }
}
