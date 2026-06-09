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

enum ConsecutivePlayGrouper {
    struct Group<Member, MemberID: Hashable> {
        let representative: Member
        let count: Int
        let memberIDs: [MemberID]
    }

    static func groups<Member, MemberID: Hashable>(
        from members: [Member],
        shouldGroup: (Member) -> Bool,
        dedupeKey: (Member) -> String,
        memberID: (Member) -> MemberID
    ) -> [Group<Member, MemberID>] {
        guard let first = members.first else { return [] }

        var groups: [Group<Member, MemberID>] = []
        var currentRepresentative = first
        var currentCount = 1
        var currentMemberIDs = [memberID(first)]
        var currentShouldGroup = shouldGroup(first)
        var currentDedupeKey = dedupeKey(first)

        for member in members.dropFirst() {
            let nextShouldGroup = shouldGroup(member)
            let nextDedupeKey = dedupeKey(member)
            let nextMemberID = memberID(member)

            if currentShouldGroup, nextShouldGroup, currentDedupeKey == nextDedupeKey {
                currentCount += 1
                currentMemberIDs.append(nextMemberID)
                continue
            }

            groups.append(
                Group(
                    representative: currentRepresentative,
                    count: currentCount,
                    memberIDs: currentMemberIDs
                )
            )

            currentRepresentative = member
            currentCount = 1
            currentMemberIDs = [nextMemberID]
            currentShouldGroup = nextShouldGroup
            currentDedupeKey = nextDedupeKey
        }

        groups.append(
            Group(
                representative: currentRepresentative,
                count: currentCount,
                memberIDs: currentMemberIDs
            )
        )

        return groups
    }

    static func isFullySelected<MemberID: Hashable>(
        memberIDs: [MemberID],
        selectedIDs: Set<MemberID>
    ) -> Bool {
        !memberIDs.isEmpty && memberIDs.allSatisfy(selectedIDs.contains)
    }

    static func toggleSelection<MemberID: Hashable>(
        for memberIDs: [MemberID],
        in selectedIDs: Set<MemberID>
    ) -> Set<MemberID> {
        var updated = selectedIDs

        if isFullySelected(memberIDs: memberIDs, selectedIDs: selectedIDs) {
            for id in memberIDs {
                updated.remove(id)
            }
            return updated
        }

        for id in memberIDs {
            updated.insert(id)
        }
        return updated
    }
}
