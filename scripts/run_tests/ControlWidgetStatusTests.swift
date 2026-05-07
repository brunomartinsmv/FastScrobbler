import Foundation

func runControlWidgetStatusTests() {
    section("Control widget status · transient phase expiry")

    struct SimEntry {
        var phase: String
        var expiresAt: Date?
    }

    func resolvedPhase(entry: SimEntry?, now: Date) -> String {
        guard let entry else { return "idle" }
        if let expiresAt = entry.expiresAt, expiresAt <= now {
            return "idle"
        }
        return entry.phase
    }

    let now = Date()
    expectEqual("missing entry resolves to idle", resolvedPhase(entry: nil, now: now), "idle")
    expectEqual(
        "in-progress entry stays in progress",
        resolvedPhase(entry: SimEntry(phase: "inProgress", expiresAt: nil), now: now),
        "inProgress"
    )
    expectEqual(
        "success entry remains visible before expiry",
        resolvedPhase(entry: SimEntry(phase: "success", expiresAt: now.addingTimeInterval(1.5)), now: now),
        "success"
    )
    expectEqual(
        "scan-history success entry remains visible until 1.5 seconds",
        resolvedPhase(entry: SimEntry(phase: "success", expiresAt: now.addingTimeInterval(1.5)), now: now.addingTimeInterval(1.49)),
        "success"
    )
    expectEqual(
        "success entry reverts to idle at expiry",
        resolvedPhase(entry: SimEntry(phase: "success", expiresAt: now.addingTimeInterval(1.5)), now: now.addingTimeInterval(1.5)),
        "idle"
    )
}
