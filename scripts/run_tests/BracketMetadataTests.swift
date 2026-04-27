import Foundation

// ─── Replicate bracket-removal logic from Track.swift (3a) ───────────────────
// Copied verbatim from the production source so the test exercises the real algorithm.

func parentheticalContent(_ content: String, matchesWholeWordKeyword keyword: String) -> Bool {
    let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKeyword.isEmpty else { return false }
    let escapedKeyword = NSRegularExpression.escapedPattern(for: trimmedKeyword)
    let pattern = #"(?i)(?<![\p{L}\p{N}])\#(escapedKeyword)(?![\p{L}\p{N}])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(content.startIndex..<content.endIndex, in: content)
    return regex.firstMatch(in: content, range: range) != nil
}

func cleanedMetadata(from value: String, removeAll: Bool, keywords: [String]) -> (result: String, passes: Int) {
    guard removeAll || !keywords.isEmpty else { return (value, 0) }
    let pattern = #"\([^()]*\)|\[[^\[\]]*\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return (value, 0) }

    var workingValue = value
    var removedAnySegment = false
    var passesRemaining = 5
    var passesUsed = 0

    while passesRemaining > 0 {
        passesRemaining -= 1
        passesUsed += 1
        let matches = regex.matches(
            in: workingValue,
            range: NSRange(workingValue.startIndex..<workingValue.endIndex, in: workingValue)
        )
        guard !matches.isEmpty else { break }

        var rebuilt = ""
        var currentIndex = workingValue.startIndex
        var removedOnThisPass = false

        for match in matches {
            guard let range = Range(match.range, in: workingValue) else { continue }
            let segment = String(workingValue[range])
            let inner = String(segment.dropFirst().dropLast())
            let shouldRemove = removeAll || keywords.contains { keyword in
                parentheticalContent(inner, matchesWholeWordKeyword: keyword)
            }
            if shouldRemove {
                rebuilt += String(workingValue[currentIndex..<range.lowerBound])
                removedOnThisPass = true
            } else {
                rebuilt += String(workingValue[currentIndex..<range.upperBound])
            }
            currentIndex = range.upperBound
        }

        rebuilt += String(workingValue[currentIndex...])
        guard removedOnThisPass else { break }
        workingValue = rebuilt
        removedAnySegment = true
    }

    guard removedAnySegment else { return (value, passesUsed) }

    let normalizedWhitespace = workingValue.replacingOccurrences(
        of: #"\s+"#, with: " ", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    return (normalizedWhitespace.isEmpty ? value : normalizedWhitespace, passesUsed)
}

func runBracketRemovalTests() {
    // ─── 3a: Bracket removal ─────────────────────────────────────────────────────

    section("3a · Bracket removal — basic correctness")

    let r1 = cleanedMetadata(from: "Song (feat. Artist)", removeAll: false, keywords: ["feat."])
    expect("removes (feat. Artist)", r1.result == "Song", detail: "got '\(r1.result)'")

    let r2 = cleanedMetadata(from: "Song [Remix]", removeAll: false, keywords: ["Remix"])
    expect("removes [Remix]", r2.result == "Song", detail: "got '\(r2.result)'")

    let r3 = cleanedMetadata(from: "Song (Live) [Remaster]", removeAll: false, keywords: ["Live", "Remaster"])
    expect("removes multiple brackets", r3.result == "Song", detail: "got '\(r3.result)'")

    let r4 = cleanedMetadata(from: "Song (Official Video)", removeAll: false, keywords: ["feat."])
    expect("keeps non-matching brackets", r4.result == "Song (Official Video)", detail: "got '\(r4.result)'")

    let r5 = cleanedMetadata(from: "Song (feat. Artist)", removeAll: true, keywords: [])
    expect("removeAll strips any brackets", r5.result == "Song", detail: "got '\(r5.result)'")

    let r6 = cleanedMetadata(from: "Just a Song", removeAll: false, keywords: ["feat."])
    expect("no brackets = no change", r6.result == "Just a Song", detail: "got '\(r6.result)'")

    section("3a · Bracket removal — nested brackets (pass cap)")

    // Nesting like (feat. (A)) requires 2 passes: inner first, then outer.
    // The cap is 5, so all reasonable nesting should resolve.
    let nested1 = cleanedMetadata(from: "Song (feat. (Artist))", removeAll: true, keywords: [])
    expect("2-deep nesting resolves within 5 passes", nested1.passes <= 5, detail: "passes=\(nested1.passes)")
    expect("2-deep nesting removes all brackets", nested1.result == "Song", detail: "got '\(nested1.result)'")

    let nested2 = cleanedMetadata(from: "Song (feat. (A (B (C (D)))))", removeAll: true, keywords: [])
    expect("5-deep nesting uses ≤5 passes (cap enforced)", nested2.passes <= 5, detail: "passes=\(nested2.passes)")

    // Verify the cap actually terminates: construct pathologically deep nesting
    let deep = "Song " + String(repeating: "(", count: 10) + "x" + String(repeating: ")", count: 10)
    let r7 = cleanedMetadata(from: deep, removeAll: true, keywords: [])
    expect("pathological nesting terminates (passes ≤ 5)", r7.passes <= 5, detail: "passes=\(r7.passes)")

    section("3a · Bracket removal — keyword boundary matching")

    let r8 = cleanedMetadata(from: "Song (Remastered)", removeAll: false, keywords: ["Remaster"])
    expect("keyword partial match inside word is NOT removed", r8.result == "Song (Remastered)", detail: "got '\(r8.result)'")

    let r9 = cleanedMetadata(from: "Song (2024 Remaster)", removeAll: false, keywords: ["Remaster"])
    expect("keyword as whole word IS removed", r9.result == "Song", detail: "got '\(r9.result)'")

    let r10 = cleanedMetadata(from: "Song (LIVE)", removeAll: false, keywords: ["live"])
    expect("keyword match is case-insensitive", r10.result == "Song", detail: "got '\(r10.result)'")

    let r11 = cleanedMetadata(from: "Song (feat. Artist)", removeAll: false, keywords: ["  feat.  "])
    expect("keyword surrounding whitespace is ignored", r11.result == "Song", detail: "got '\(r11.result)'")

    let r12 = cleanedMetadata(from: "Song (Live)  [Official Video]", removeAll: false, keywords: ["Live"])
    expect("removing one segment normalizes surrounding whitespace", r12.result == "Song [Official Video]", detail: "got '\(r12.result)'")
}

func runAdditionalBracketEdgeCaseTests() {
    // ─── Bracket removal — additional edge cases ──────────────────────────────────

    section("3a · Bracket removal — additional edge cases")

    let edgeEmpty   = cleanedMetadata(from: "Song ()", removeAll: true, keywords: [])
    expect("empty brackets removed with removeAll",     edgeEmpty.result == "Song", detail: "got '\(edgeEmpty.result)'")

    let edgeSpace   = cleanedMetadata(from: "Song ( )", removeAll: true, keywords: [])
    expect("whitespace-only brackets removed",          edgeSpace.result == "Song", detail: "got '\(edgeSpace.result)'")

    let edgeUnicode = cleanedMetadata(from: "Song (フィーチャー)", removeAll: true, keywords: [])
    expect("unicode content inside brackets removed",   edgeUnicode.result == "Song", detail: "got '\(edgeUnicode.result)'")

    let edgeSqKey   = cleanedMetadata(from: "Song [feat. Artist]", removeAll: false, keywords: ["feat."])
    expect("square bracket keyword match removed",      edgeSqKey.result == "Song", detail: "got '\(edgeSqKey.result)'")

    // When removing all brackets would leave an empty string, return the original.
    let edgeOnlyBracket = cleanedMetadata(from: "(feat. X)", removeAll: true, keywords: [])
    expect("result empty after removal → keep original", edgeOnlyBracket.result == "(feat. X)", detail: "got '\(edgeOnlyBracket.result)'")

    // ─── API signature generation ─────────────────────────────────────────────────
}
