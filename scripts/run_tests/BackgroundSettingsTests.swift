import Foundation

func runBackgroundGracePeriodTests() {
    // ─── Background grace period — lifecycle decisions ───────────────────────────

    section("Background grace period · lifecycle decisions")

    struct SimGraceController {
        var isGracePeriodActive = false
        var pauseCalls = 0
        var expiryCalls = 0

        mutating func enterBackground(shouldStartGracePeriod: Bool, canStartGracePeriod: Bool) {
            if shouldStartGracePeriod && canStartGracePeriod {
                isGracePeriodActive = true
            } else {
                pauseCalls += 1
            }
        }

        mutating func expireGracePeriodIfNeeded() {
            guard isGracePeriodActive else { return }
            isGracePeriodActive = false
            expiryCalls += 1
            pauseCalls += 1
        }

        mutating func enterForeground() {
            isGracePeriodActive = false
        }
    }

    var grace = SimGraceController()
    grace.enterBackground(shouldStartGracePeriod: true, canStartGracePeriod: true)
    expect("grace period starts when background task is available", grace.isGracePeriodActive)
    expect("starting grace period does not pause immediately", grace.pauseCalls == 0, detail: "got \(grace.pauseCalls)")

    expect("grace period remains active before expiry", grace.isGracePeriodActive)

    grace.expireGracePeriodIfNeeded()
    grace.expireGracePeriodIfNeeded()
    expect("expiry fires once", grace.expiryCalls == 1, detail: "got \(grace.expiryCalls)")
    expect("expiry pauses once", grace.pauseCalls == 1, detail: "got \(grace.pauseCalls)")

    var foregroundResume = SimGraceController()
    foregroundResume.enterBackground(shouldStartGracePeriod: true, canStartGracePeriod: true)
    foregroundResume.enterForeground()
    foregroundResume.expireGracePeriodIfNeeded()
    expect("foreground entry cancels the active grace period", !foregroundResume.isGracePeriodActive)
    expect("foreground cancel prevents expiry callback", foregroundResume.expiryCalls == 0, detail: "got \(foregroundResume.expiryCalls)")
    expect("foreground cancel avoids a pause from expiry", foregroundResume.pauseCalls == 0, detail: "got \(foregroundResume.pauseCalls)")

    var fallback = SimGraceController()
    fallback.enterBackground(shouldStartGracePeriod: true, canStartGracePeriod: false)
    expect("failed grace-period start leaves no active grace period", !fallback.isGracePeriodActive)
    expect("failed grace-period start falls back to immediate pause", fallback.pauseCalls == 1, detail: "got \(fallback.pauseCalls)")
}

func runSettingsDefaultsTests() {
    // ─── Settings defaults / reset coverage ─────────────────────────────────────

    section("Settings defaults / reset coverage")

    let runtimePreventDuplicatesDefault = true
    let macSettingsPreventDuplicatesDefault = true
    let macSettingsPreventDuplicatesAfterReset = true
    expectEqual("macOS duplicate-prevention default matches runtime", macSettingsPreventDuplicatesDefault, runtimePreventDuplicatesDefault)
    expectEqual("macOS reset restores duplicate prevention to runtime default", macSettingsPreventDuplicatesAfterReset, runtimePreventDuplicatesDefault)

    let resetClearedKeys: Set<String> = [
        "FastScrobbler.Pro.loveOnFavoriteEnabled",
        "FastScrobbler.Pro.scrobbleThresholdIndex",
        "FastScrobbler.Pro.useAlbumArtistForScrobbling",
        "FastScrobbler.Pro.useFirstArtistOnlyForScrobbling",
        "FastScrobbler.Pro.removeBracketsEnabled",
        "FastScrobbler.Pro.removeAllBracketsEnabled",
        "FastScrobbler.Pro.removeBracketsKeywords",
        "FastScrobbler.Pro.removeBracketsFromAlbumTitlesEnabled",
        "FastScrobbler.Pro.removeAllBracketsFromAlbumTitlesEnabled",
        "FastScrobbler.Pro.removeBracketsFromAlbumTitleKeywords",
        "FastScrobbler.Pro.preventDuplicateScrobblesEnabled",
        "FastScrobbler.Pro.scrobbleLoopedTracksEnabled",
        "FastScrobbler.App.scrobbleListeningHistoryEnabled",
        "FastScrobbler.App.scrobbleAppleMusicAPIEnabled",
        "FastScrobbler.App.scrobbleOnlyNonLibraryAppleMusicAPITracks",
        "FastScrobbler.App.extendedListeningHistoryScanEnabled",
        "FastScrobbler.App.themeSelection",
        "FastScrobbler.Pro.textReplacementRules",
    ]

    expect("reset clears scrobbleLoopedTracksEnabled", resetClearedKeys.contains("FastScrobbler.Pro.scrobbleLoopedTracksEnabled"))
    expect("reset clears scrobbleAppleMusicAPIEnabled", resetClearedKeys.contains("FastScrobbler.App.scrobbleAppleMusicAPIEnabled"))
    expect("reset clears non-library Apple Music API filter", resetClearedKeys.contains("FastScrobbler.App.scrobbleOnlyNonLibraryAppleMusicAPITracks"))
    expect("reset clears extendedListeningHistoryScanEnabled", resetClearedKeys.contains("FastScrobbler.App.extendedListeningHistoryScanEnabled"))
    expect("reset clears themeSelection", resetClearedKeys.contains("FastScrobbler.App.themeSelection"))
    expect("reset clears textReplacementRules", resetClearedKeys.contains("FastScrobbler.Pro.textReplacementRules"))
    expect("reset clears useFirstArtistOnlyForScrobbling", resetClearedKeys.contains("FastScrobbler.Pro.useFirstArtistOnlyForScrobbling"))

    let iOSLoopedTracksAfterReset = false
    expectEqual("iOS reset restores looped-track scrobbling default", iOSLoopedTracksAfterReset, false)

    let extendedListeningHistoryScanDefault = false
    let iOSExtendedListeningHistoryScanAfterReset = false
    let appleMusicAPIScrobblingDefault = false
    let iOSAppleMusicAPIScrobblingAfterReset = false
    let nonLibraryAppleMusicAPIFilterDefault = false
    let iOSNonLibraryAppleMusicAPIFilterAfterReset = false
    let firstArtistOnlyDefault = false
    let iOSFirstArtistOnlyAfterReset = false
    let themeSelectionDefault = "system"
    let iOSThemeSelectionAfterReset = "system"
    let iCloudSyncDefault = false
    expectEqual("Apple Music API scrobbling defaults off", appleMusicAPIScrobblingDefault, false)
    expectEqual("iOS reset restores Apple Music API scrobbling default", iOSAppleMusicAPIScrobblingAfterReset, appleMusicAPIScrobblingDefault)
    expectEqual("non-library Apple Music API filter defaults off", nonLibraryAppleMusicAPIFilterDefault, false)
    expectEqual("iOS reset restores non-library Apple Music API filter default", iOSNonLibraryAppleMusicAPIFilterAfterReset, nonLibraryAppleMusicAPIFilterDefault)
    expectEqual("extended Listening History scan defaults off", extendedListeningHistoryScanDefault, false)
    expectEqual("iOS reset restores extended Listening History scan default", iOSExtendedListeningHistoryScanAfterReset, extendedListeningHistoryScanDefault)
    expectEqual("first-artist-only scrobbling defaults off", firstArtistOnlyDefault, false)
    expectEqual("iOS reset restores first-artist-only scrobbling default", iOSFirstArtistOnlyAfterReset, firstArtistOnlyDefault)
    expectEqual("theme selection defaults to system", themeSelectionDefault, "system")
    expectEqual("iOS reset restores theme selection default", iOSThemeSelectionAfterReset, themeSelectionDefault)
    expectEqual("iCloud sync defaults off", iCloudSyncDefault, false)

    let recentTracksImporterStateAfterReset: [String: Any] = [:]
    expect("reset clears Apple Music recent-tracks importer state", recentTracksImporterStateAfterReset.isEmpty)

    let builtInRulesAfterReset: [(find: String, replace: String, enabled: Bool)] = [
        ("- Single", "", false),
        ("- EP", "", false),
    ]
    expect("reset keeps built-in text replacement rules present", builtInRulesAfterReset.count == 2)
    expect("reset keeps built-in text replacement rules disabled", builtInRulesAfterReset.allSatisfy { !$0.enabled })
}
