import Foundation

func runBacklogFlushContinuationTests() {
    // ─── 3c: Flush loop continues on error ───────────────────────────────────────

    section("3c · Backlog flush — continues past failed item")

    // Simulate the flush loop logic: items are processed in order; a failure on
    // item N should increment idx (continue) rather than break.
    struct FakeItem { let id: Int; var attempts: Int }

    func simulateFlush(items: inout [FakeItem], failOnID: Int) -> (sent: [Int], failed: [Int]) {
        var idx = 0
        var sent: [Int] = []
        var failed: [Int] = []

        while idx < items.count {
            let item = items[idx]
            if item.id == failOnID {
                items[idx].attempts += 1
                failed.append(item.id)
                idx += 1   // <-- the fix: continue, not break
            } else {
                sent.append(item.id)
                items.remove(at: idx)
            }
        }
        return (sent, failed)
    }

    var items = [FakeItem(id: 1, attempts: 0),
                 FakeItem(id: 2, attempts: 0),
                 FakeItem(id: 3, attempts: 0)]
    let result = simulateFlush(items: &items, failOnID: 2)

    expect("item 1 sent despite item 2 failure", result.sent.contains(1))
    expect("item 3 sent despite item 2 failure", result.sent.contains(3))
    expect("failed item 2 increments attempt count", items.first(where: { $0.id == 2 })?.attempts == 1)
    expect("failed item stays in queue", items.contains(where: { $0.id == 2 }))
    expect("successful items removed from queue", !items.contains(where: { $0.id == 1 || $0.id == 3 }))
}
