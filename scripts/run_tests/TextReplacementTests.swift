import Foundation

func runTextReplacementTests() {
    // ─── Text Replacement — basic rule application ────────────────────────────────
    // Replicates Track.applyingTextReplacements(_:) from Track.swift.

    section("Text Replacement · Basic rule application")

    enum TRScope { case all, artist, track, album }
    struct TRRule { var find: String; var replace: String; var scope: TRScope; var isEnabled: Bool = true }

    struct TRTrack {
        var artist: String
        var title: String
        var album: String?

        func applyingTextReplacements(_ rules: [TRRule]) -> TRTrack {
            var copy = self
            for rule in rules {
                guard !rule.find.isEmpty, rule.isEnabled else { continue }
                switch rule.scope {
                case .all:
                    copy.artist = copy.artist.replacingOccurrences(of: rule.find, with: rule.replace)
                    copy.title  = copy.title.replacingOccurrences(of: rule.find, with: rule.replace)
                    copy.album  = copy.album?.replacingOccurrences(of: rule.find, with: rule.replace)
                case .artist:
                    copy.artist = copy.artist.replacingOccurrences(of: rule.find, with: rule.replace)
                case .track:
                    copy.title  = copy.title.replacingOccurrences(of: rule.find, with: rule.replace)
                case .album:
                    copy.album  = copy.album?.replacingOccurrences(of: rule.find, with: rule.replace)
                }
            }
            return copy
        }
    }

    let baseTrack = TRTrack(artist: "Artist ft. Guest", title: "Song (Live)", album: "Album - EP")

    let trAll = baseTrack.applyingTextReplacements([TRRule(find: "ft. Guest", replace: "", scope: .all)])
    expect("scope=all replaces in artist",  trAll.artist == "Artist ", detail: "got '\(trAll.artist)'")
    expect("scope=all: album unchanged if no match", trAll.album == "Album - EP")

    let trArtist = baseTrack.applyingTextReplacements([TRRule(find: " ft. Guest", replace: "", scope: .artist)])
    expect("scope=artist replaces in artist",  trArtist.artist == "Artist",         detail: "got '\(trArtist.artist)'")
    expect("scope=artist title unchanged",     trArtist.title  == "Song (Live)",     detail: "got '\(trArtist.title)'")
    expect("scope=artist album unchanged",     trArtist.album  == "Album - EP",      detail: "got '\(trArtist.album ?? "nil")'")

    let trTrack = baseTrack.applyingTextReplacements([TRRule(find: " (Live)", replace: "", scope: .track)])
    expect("scope=track replaces in title",   trTrack.title   == "Song",             detail: "got '\(trTrack.title)'")
    expect("scope=track artist unchanged",    trTrack.artist  == "Artist ft. Guest", detail: "got '\(trTrack.artist)'")
    expect("scope=track album unchanged",     trTrack.album   == "Album - EP",       detail: "got '\(trTrack.album ?? "nil")'")

    let trAlbum = baseTrack.applyingTextReplacements([TRRule(find: " - EP", replace: "", scope: .album)])
    expect("scope=album replaces in album",   trAlbum.album   == "Album",            detail: "got '\(trAlbum.album ?? "nil")'")
    expect("scope=album artist unchanged",    trAlbum.artist  == "Artist ft. Guest", detail: "got '\(trAlbum.artist)'")
    expect("scope=album title unchanged",     trAlbum.title   == "Song (Live)",      detail: "got '\(trAlbum.title)'")

    // ─── Text Replacement — disabled rules skipped ───────────────────────────────

    section("Text Replacement · Disabled rules are skipped")

    let disabledRule = TRRule(find: "ft. Guest", replace: "", scope: .all, isEnabled: false)
    let trDisabled = baseTrack.applyingTextReplacements([disabledRule])
    expect("disabled rule does not modify artist", trDisabled.artist == baseTrack.artist, detail: "got '\(trDisabled.artist)'")
    expect("disabled rule does not modify title",  trDisabled.title  == baseTrack.title,  detail: "got '\(trDisabled.title)'")

    // ─── Text Replacement — empty find string skipped ────────────────────────────

    section("Text Replacement · Empty find string is skipped")

    let emptyFindRule = TRRule(find: "", replace: "X", scope: .all)
    let trEmptyFind = baseTrack.applyingTextReplacements([emptyFindRule])
    expect("empty find does not modify artist", trEmptyFind.artist == baseTrack.artist, detail: "got '\(trEmptyFind.artist)'")
    expect("empty find does not modify title",  trEmptyFind.title  == baseTrack.title,  detail: "got '\(trEmptyFind.title)'")

    // ─── Text Replacement — multiple rules applied in order ──────────────────────

    section("Text Replacement · Multiple rules applied sequentially")

    let multiTrack = TRTrack(artist: "Artist ft. Guest A & B", title: "Song", album: nil)
    let multiRules: [TRRule] = [
        TRRule(find: " ft. Guest A", replace: "", scope: .artist),
        TRRule(find: " & B", replace: "", scope: .artist),
    ]
    let trMulti = multiTrack.applyingTextReplacements(multiRules)
    expect("first rule applied", trMulti.artist.contains("ft. Guest A") == false, detail: "got '\(trMulti.artist)'")
    expect("second rule applied", trMulti.artist == "Artist", detail: "got '\(trMulti.artist)'")

    // ─── Text Replacement — nil album not modified ────────────────────────────────

    section("Text Replacement · Nil album is unaffected by album-scope rule")

    let nilAlbumTrack = TRTrack(artist: "Artist", title: "Song", album: nil)
    let trNilAlbum = nilAlbumTrack.applyingTextReplacements([TRRule(find: "x", replace: "y", scope: .album)])
    expect("nil album stays nil after album-scope rule", trNilAlbum.album == nil)

    let trNilAlbumAll = nilAlbumTrack.applyingTextReplacements([TRRule(find: "x", replace: "y", scope: .all)])
    expect("nil album stays nil after all-scope rule", trNilAlbumAll.album == nil)

    // ─── Text Replacement — built-in rules (EP / Single suffix) ──────────────────
    // The built-in rules are album-scoped, disabled by default.
    // When enabled they strip "- EP" / "- Single" from album titles.

    section("Text Replacement · Built-in EP and Single suffix rules")

    let builtInRules: [TRRule] = [
        TRRule(find: "- Single", replace: "", scope: .album, isEnabled: true),
        TRRule(find: "- EP",     replace: "", scope: .album, isEnabled: true),
    ]

    let epTrack     = TRTrack(artist: "A", title: "T", album: "Folklore - EP")
    let singleTrack = TRTrack(artist: "A", title: "T", album: "Circles - Single")
    let plainTrack  = TRTrack(artist: "A", title: "T", album: "Regular Album")

    // Text replacement uses plain replacingOccurrences, so the find string must match exactly.
    // "Folklore - EP" with find="- EP" leaves "Folklore " (with trailing space).
    // The Pro EP/Single stripping (strippingEpAndSingleSuffixFromAlbumIfPresent) is a separate
    // code path that also trims whitespace — text replacement does not trim.
    expect("'- EP' stripped from album (trailing space preserved by plain replace)",
           epTrack.applyingTextReplacements(builtInRules).album == "Folklore ",       detail: "got '\(epTrack.applyingTextReplacements(builtInRules).album ?? "nil")'")
    expect("'- Single' stripped from album (trailing space preserved by plain replace)",
           singleTrack.applyingTextReplacements(builtInRules).album == "Circles ",    detail: "got '\(singleTrack.applyingTextReplacements(builtInRules).album ?? "nil")'")
    expect("plain album name unchanged",     plainTrack.applyingTextReplacements(builtInRules).album == "Regular Album", detail: "got '\(plainTrack.applyingTextReplacements(builtInRules).album ?? "nil")'")

    let disabledBuiltIns: [TRRule] = [
        TRRule(find: "- Single", replace: "", scope: .album, isEnabled: false),
        TRRule(find: "- EP",     replace: "", scope: .album, isEnabled: false),
    ]
    expect("disabled built-in: EP suffix kept",     epTrack.applyingTextReplacements(disabledBuiltIns).album == "Folklore - EP",    detail: "got '\(epTrack.applyingTextReplacements(disabledBuiltIns).album ?? "nil")'")
    expect("disabled built-in: Single suffix kept", singleTrack.applyingTextReplacements(disabledBuiltIns).album == "Circles - Single", detail: "got '\(singleTrack.applyingTextReplacements(disabledBuiltIns).album ?? "nil")'")

    // ─── Text Replacement — replace with non-empty string ────────────────────────

    section("Text Replacement · Replacement with non-empty substitute string")

    let subTrack = TRTrack(artist: "Sy & Unknown Mortal Orchestra", title: "Soulmate", album: nil)
    let subRule  = TRRule(find: "Sy & ", replace: "", scope: .artist)
    expect("prefix stripped leaving remainder", subTrack.applyingTextReplacements([subRule]).artist == "Unknown Mortal Orchestra",
           detail: "got '\(subTrack.applyingTextReplacements([subRule]).artist)'")

    let canonRule = TRRule(find: "The Weeknd", replace: "Abel Tesfaye", scope: .artist)
    let weekndTrack = TRTrack(artist: "The Weeknd", title: "Blinding Lights", album: nil)
    expect("replacement substitutes full artist name",
           weekndTrack.applyingTextReplacements([canonRule]).artist == "Abel Tesfaye",
           detail: "got '\(weekndTrack.applyingTextReplacements([canonRule]).artist)'")

    // ─── Text Replacement — case-sensitive exact matching ────────────────────────

    section("Text Replacement · Case-sensitive exact matching")

    let caseTrack = TRTrack(artist: "ARTIST", title: "song", album: nil)
    let lcRule    = TRRule(find: "artist", replace: "", scope: .artist)   // lowercase — shouldn't match "ARTIST"
    expect("lowercase find does not match uppercase artist", caseTrack.applyingTextReplacements([lcRule]).artist == "ARTIST",
           detail: "got '\(caseTrack.applyingTextReplacements([lcRule]).artist)'")
}
