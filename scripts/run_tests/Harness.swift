import Foundation

var passed = 0
var failed = 0

func expect(_ label: String, _ condition: Bool, detail: String = "") {
    if condition {
        print("  ✓ \(label)")
        passed += 1
    } else {
        let suffix = detail.isEmpty ? "" : " — \(detail)"
        print("  ✗ \(label)\(suffix)")
        failed += 1
    }
}

func section(_ title: String) {
    print("\n\(title)")
}

func expectEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    expect(label, actual == expected, detail: "got '\(actual)', expected '\(expected)'")
}

func finishTests() {
    print("\n────────────────────────────────────────")
    let total = passed + failed
    print("Results: \(passed)/\(total) passed", failed > 0 ? "(\(failed) FAILED)" : "")
    if failed > 0 { exit(1) }
}
