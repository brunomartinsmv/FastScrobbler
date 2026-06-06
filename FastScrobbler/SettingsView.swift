import SwiftUI
import ActivityKit

let proYellow = Color(red: 0.89, green: 0.71, blue: 0.16)

struct SettingsView: View {
    private static let repositoryURL = URL(string: "https://github.com/kevinlim512/FastScrobbler")!
    private static let redditURL = URL(string: "https://www.reddit.com/r/FastScrobbler/")!
    private static let redditSubmitURL = URL(string: "https://www.reddit.com/r/FastScrobbler/submit")!
    private static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6759501541?action=write-review")!
    // Last.fm brand red, used for the links section background
    private static let linksSectionRed = Color(red: 0.72, green: 0.14, blue: 0.14)
    // Insets position the Pro badge overlay to sit just inside the disclosure indicator / toggle
    private static let iosLockedProNavigationBadgeTrailingInset: CGFloat = 24
    private static let iosLockedProToggleBadgeTrailingInset: CGFloat = 75

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    @AppStorage(LiveActivityManager.enabledDefaultsKey) private var liveActivityEnabled = false
    @AppStorage(ProSettings.Keys.loveOnFavoriteEnabled, store: AppGroup.userDefaults) private var loveOnFavoriteEnabled = false
    @AppStorage(ProSettings.Keys.scrobbleThresholdIndex, store: AppGroup.userDefaults) private var scrobbleThresholdIndex = ProSettings.defaultScrobbleThresholdIndex
    @AppStorage(ProSettings.Keys.useAlbumArtistForScrobbling, store: AppGroup.userDefaults) private var useAlbumArtistForScrobbling = false
    @AppStorage(ProSettings.Keys.useFirstArtistOnlyForScrobbling, store: AppGroup.userDefaults) private var useFirstArtistOnlyForScrobbling = false
    @AppStorage(ProSettings.Keys.removeBracketsFromSongTitlesEnabled, store: AppGroup.userDefaults) private var removeBracketsFromSongTitlesEnabled = false
    @AppStorage(ProSettings.Keys.removeAllBracketsFromSongTitlesEnabled, store: AppGroup.userDefaults) private var removeAllBracketsFromSongTitlesEnabled = false
    @AppStorage(ProSettings.Keys.removeBracketsFromAlbumTitlesEnabled, store: AppGroup.userDefaults) private var removeBracketsFromAlbumTitlesEnabled = false
    @AppStorage(ProSettings.Keys.removeAllBracketsFromAlbumTitlesEnabled, store: AppGroup.userDefaults) private var removeAllBracketsFromAlbumTitlesEnabled = false
    @AppStorage(ProSettings.Keys.preventDuplicateScrobblesEnabled, store: AppGroup.userDefaults) private var preventDuplicateScrobblesEnabled = true
    @AppStorage(AppSettings.Keys.scrobbleListeningHistoryEnabled, store: AppGroup.userDefaults) private var scrobbleListeningHistoryEnabled = true
    @AppStorage(AppSettings.Keys.scrobbleAppleMusicAPIEnabled, store: AppGroup.userDefaults) private var scrobbleAppleMusicAPIEnabled = false
    @AppStorage(AppSettings.Keys.scrobbleOnlyNonLibraryAppleMusicAPITracks, store: AppGroup.userDefaults) private var scrobbleOnlyNonLibraryAppleMusicAPITracks = true
    @AppStorage(AppSettings.Keys.extendedListeningHistoryScanEnabled, store: AppGroup.userDefaults) private var extendedListeningHistoryScanEnabled = false
    @AppStorage(AppSettings.Keys.sendNowPlayingAutomaticallyEnabled, store: AppGroup.userDefaults) private var sendNowPlayingAutomaticallyEnabled = true
    @AppStorage(AppSettings.Keys.themeSelection) private var themeSelectionRawValue = AppTheme.system.rawValue
    @AppStorage(AppSettings.Keys.buttonThemeSelection) private var buttonThemeSelectionRawValue = ButtonTheme.colorful.rawValue

    @EnvironmentObject private var auth: LastFMAuthManager
    @EnvironmentObject private var engine: ScrobbleEngine
    @EnvironmentObject private var pro: ProPurchaseManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isEmbeddedInTab) private var isEmbeddedInTab

    private enum ActiveAlert: Identifiable {
        case logoutConfirmation
        case resetConfirmation
        case listeningHistoryScanResult(message: String)

        var id: String {
            switch self {
            case .logoutConfirmation:
                return "logoutConfirmation"
            case .resetConfirmation:
                return "resetConfirmation"
            case .listeningHistoryScanResult(let message):
                return "listeningHistoryScanResult-\(message)"
            }
        }
    }

    fileprivate enum SettingsRoute: Hashable {
        case appStorage
        case appleMusicAPI
        case debug
        case removeBracketsFromSongTitles
        case removeBracketsFromAlbumTitles
        case textReplacement
        case proUpgrade
    }

    @State private var activeAlert: ActiveAlert?
    @State private var isSigningInToLastFM = false
    @State private var lastFMLoginErrorText: String?
    @State private var isScanningListeningHistory = false
    @State private var isShowingWhatsNew = false
    @State private var navigationPath = NavigationPath()
    var isShowingHelp: Binding<Bool>?

    init(isShowingHelp: Binding<Bool>? = nil) {
        self.isShowingHelp = isShowingHelp
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            settingsRootContent
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .appStorage:
                        AppStorageSettingsPage()
                    case .appleMusicAPI:
                        AppleMusicAPISettingsPage()
                    case .debug:
                        DebugSettingsPage()
                    case .removeBracketsFromSongTitles:
                        RemoveBracketsSettingsPage(target: .songTitles)
                    case .removeBracketsFromAlbumTitles:
                        RemoveBracketsSettingsPage(target: .albumTitles)
                    case .textReplacement:
                        TextReplacementSettingsPage()
                    case .proUpgrade:
                        ProUpgradeView()
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    if !isEmbeddedInTab {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                dismiss()
                            } label: {
                                IOSCloseButtonLabel(style: .plain)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close")
                        }
                    }
                }
        }
        .task {
            await auth.refreshUserInfoIfNeeded()
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .logoutConfirmation:
                Alert(
                    title: Text("Sign Out of Last.fm?"),
                    message: Text("You'll need to sign in again to scrobble."),
                    primaryButton: .destructive(Text("Sign Out"), action: performLogout),
                    secondaryButton: .cancel()
                )
            case .resetConfirmation:
                Alert(
                    title: Text("Reset Settings?"),
                    message: Text("This will restore all settings to their defaults."),
                    primaryButton: .destructive(Text("Reset"), action: resetToInitialSettings),
                    secondaryButton: .cancel()
                )
            case .listeningHistoryScanResult(let message):
                Alert(
                    title: Text("Listening History"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .alert("Couldn't sign in to Last.fm", isPresented: Binding(
            get: { lastFMLoginErrorText != nil },
            set: { isPresented in
                if !isPresented {
                    lastFMLoginErrorText = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastFMLoginErrorText ?? "")
        }
        .fullScreenCover(isPresented: $isShowingWhatsNew) {
            WhatsNewView {
                isShowingWhatsNew = false
            }
        }
    }

    @ViewBuilder
    private var settingsRootContent: some View {
        Form {
            Section(pro.isPro ? "Thank you! ^_^" : "Unlock Pro features") {
                proUpgradeNavigationRow
            }

            if let isShowingHelp {
                Section {
                    Button {
                        isShowingHelp.wrappedValue = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "questionmark.circle")
                            Text("Help")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .listSectionSpacing(.compact)
            }

            Section("Scrobble Controls") {
                appleMusicAPINavigationLink
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Prevent duplicate scrobbles", isOn: $preventDuplicateScrobblesEnabled)
                    Text("Avoids sending the same playback session to Last.fm more than once within a short time window.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Send Now Playing status to Last.fm", isOn: $sendNowPlayingAutomaticallyEnabled)
                    Text("Display the currently playing track on your Last.fm profile. Automatic scrobbles still work when this is off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                scrobbleThresholdSlider()
                removeBracketsNavigationLink(target: .songTitles)
                removeBracketsNavigationLink(target: .albumTitles)
                textReplacementNavigationLink
                Toggle(isOn: proLockedBoolBinding($loveOnFavoriteEnabled, unlockedDefault: false)) {
                    HStack {
                        Text("Love Apple Music favourites on Last.fm")
                            .foregroundStyle(pro.isPro ? .primary : .secondary)
                        Spacer()
                        proFeatureBadgePlaceholder
                    }
                }
                .disabled(!pro.isPro)
                .tint(proYellow)
                .overlay(alignment: .trailing) {
                    lockedProBadgeOverlay(trailingInset: Self.iosLockedProToggleBadgeTrailingInset)
                }
                Toggle(isOn: proLockedBoolBinding($useAlbumArtistForScrobbling, unlockedDefault: false)) {
                    HStack {
                        Text("Replace song artist with album artist when scrobbling")
                            .foregroundStyle(pro.isPro ? .primary : .secondary)
                        Spacer()
                        proFeatureBadgePlaceholder
                    }
                }
                .disabled(!pro.isPro)
                .tint(proYellow)
                .overlay(alignment: .trailing) {
                    lockedProBadgeOverlay(trailingInset: Self.iosLockedProToggleBadgeTrailingInset)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: proLockedBoolBinding($useFirstArtistOnlyForScrobbling, unlockedDefault: false)) {
                        HStack {
                            Text("Scrobble only the first credited artist")
                                .foregroundStyle(pro.isPro ? .primary : .secondary)
                            Spacer()
                            proFeatureBadgePlaceholder
                        }
                    }
                    .disabled(!pro.isPro)
                    .tint(proYellow)
                    .overlay(alignment: .trailing) {
                        lockedProBadgeOverlay(trailingInset: Self.iosLockedProToggleBadgeTrailingInset)
                    }

                    Text("When a song lists multiple artists separated by \"&\" or commas, only scrobble the first artist.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Listening History") {
                Button {
                    Task { await scanListeningHistoryTapped() }
                } label: {
                    Label(
                        isScanningListeningHistory ? NSLocalizedString("Scanning…", comment: "") : NSLocalizedString("Scan Listening History", comment: ""),
                        systemImage: "clock.arrow.circlepath"
                    )
                    .foregroundStyle(auth.sessionKey != nil && (scrobbleListeningHistoryEnabled || scrobbleAppleMusicAPIEnabled) ? .primary : .secondary)
                }
                .padding(.vertical, 8)
                .disabled(auth.sessionKey == nil || isScanningListeningHistory || (!scrobbleListeningHistoryEnabled && !scrobbleAppleMusicAPIEnabled))

                Text(
                    scrobbleListeningHistoryEnabled
                        ? (
                            extendedListeningHistoryScanEnabled
                                ? NSLocalizedString("Scan Listening History will import plays from the past 7 days.", comment: "")
                                : NSLocalizedString("Scan Listening History will import plays from the past 36 hours.", comment: "")
                        )
                        : (
                            scrobbleAppleMusicAPIEnabled
                                ? NSLocalizedString("Scan Listening History will import up to 30 most recently played Apple Music songs.", comment: "")
                                : NSLocalizedString("Listening History scrobbling is turned off.", comment: "")
                        )
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Scrobble from Listening History", isOn: $scrobbleListeningHistoryEnabled)
                        .onValueChange(of: scrobbleListeningHistoryEnabled) { isEnabled in
                            Task { await AppModel.shared.handleListeningHistoryScrobblingChanged(isEnabled: isEnabled) }
                        }
                    Text("When off, FastScrobbler won’t import or scrobble plays from your Music app Listening History.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Extended History Scan", isOn: $extendedListeningHistoryScanEnabled)
                        .disabled(!scrobbleListeningHistoryEnabled)
                        .foregroundStyle(scrobbleListeningHistoryEnabled ? .primary : .secondary)
                    Text("When off, \"Scan Listening History\" checks the past 36 hours. When on, \"Scan Listening History\" checks the past 7 days. Automatic scans still use 36 hours.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Theme") {
                Picker("App Theme", selection: $themeSelectionRawValue) {
                    Text("System").tag(AppTheme.system.rawValue)
                    Text("Light").tag(AppTheme.light.rawValue)
                    Text("Dark").tag(AppTheme.dark.rawValue)
                }

                Picker("Button Theme", selection: $buttonThemeSelectionRawValue) {
                    Text("Colourful").tag(ButtonTheme.colorful.rawValue)
                    Text("Monochrome").tag(ButtonTheme.monochrome.rawValue)
                }
            }

            Section("Live Activity") {
                Toggle("Show Live Activity", isOn: $liveActivityEnabled)
                    .onValueChange(of: liveActivityEnabled) { isEnabled in
                        if isEnabled {
                            LiveActivityManager.shared.startIfPossible()
                        } else {
                            Task { @MainActor in
                                await LiveActivityManager.shared.stop()
                            }
                        }
                    }

                if #available(iOS 16.1, *) {
                    if !ActivityAuthorizationInfo().areActivitiesEnabled {
                        Text("Live Activities are disabled in iOS Settings for FastScrobbler.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Beta feature: shows scrobbling status on your Lock Screen and Dynamic Island.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Account") {
                HStack {
                    Text("Last.fm")
                    Spacer()
                    if auth.sessionKey != nil {
                        Text("Connected")
                            .foregroundColor(.green)
                    } else {
                        Text("Not connected")
                            .foregroundColor(.secondary)
                    }
                }

                if auth.sessionKey != nil {
                    HStack {
                        Text("Username")
                        Spacer()
                        Text(auth.username ?? NSLocalizedString("Loading…", comment: ""))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }

                let canViewProfile = (auth.sessionKey != nil && auth.profileURL != nil)
                Button {
                    if let url = auth.freshProfileURL() {
                        openURL(url)
                    }
                } label: {
                    Label("View Profile", systemImage: "person.circle")
                        .foregroundStyle(canViewProfile ? .primary : .secondary)
                }
                .disabled(!canViewProfile)

                if auth.sessionKey != nil {
                    Button(role: .destructive) {
                        activeAlert = .logoutConfirmation
                    } label: {
                        Label("Sign Out", systemImage: "power")
                    }
                } else {
                    Button {
                        Task { await connectTapped() }
                    } label: {
                        Label(isSigningInToLastFM ? NSLocalizedString("Signing In…", comment: "") : NSLocalizedString("Sign In", comment: ""), systemImage: "person.crop.circle")
                    }
                    .disabled(isSigningInToLastFM)
                }
            }

            Section("Links") {
                iosLinksBrandButton(title: "r/FastScrobbler", imageName: "reddit_logo") {
                    openURL(Self.redditURL)
                }

                iosLinksButton(title: "Ask a Question or Report a Bug", systemImage: "questionmark.bubble") {
                    openURL(Self.redditSubmitURL)
                }

                iosLinksButton(title: "Rate FastScrobbler", systemImage: "star.bubble") {
                    openURL(Self.writeReviewURL)
                }

                iosLinksBrandButton(title: "GitHub", imageName: "github_logo") {
                    openURL(Self.repositoryURL)
                }
            }

            Section {
                Button {
                    isShowingWhatsNew = true
                } label: {
                    Label("What's New", systemImage: "sparkles")
                }
            }

            Section {
                appStorageNavigationLink
                Button(role: .destructive) {
                    activeAlert = .resetConfirmation
                } label: {
                    Label("Reset Settings", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func performLogout() {
        auth.disconnect()
        engine.setUserPaused(false)
        engine.stop()
    }

    private func resetToInitialSettings() {
        UserDefaults.standard.removeObject(forKey: LiveActivityManager.enabledDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.themeSelection)
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.buttonThemeSelection)
        liveActivityEnabled = false
        themeSelectionRawValue = AppTheme.system.rawValue
        buttonThemeSelectionRawValue = ButtonTheme.colorful.rawValue
        Task { @MainActor in
            await LiveActivityManager.shared.stop()
        }

        let defaults = AppGroup.userDefaults
        defaults.removeObject(forKey: ProSettings.Keys.loveOnFavoriteEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.scrobbleThresholdIndex)
        defaults.removeObject(forKey: ProSettings.Keys.useAlbumArtistForScrobbling)
        defaults.removeObject(forKey: ProSettings.Keys.useFirstArtistOnlyForScrobbling)
        defaults.removeObject(forKey: ProSettings.Keys.removeBracketsFromSongTitlesEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.removeAllBracketsFromSongTitlesEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.removeBracketsFromSongTitleKeywords)
        defaults.removeObject(forKey: ProSettings.Keys.removeBracketsFromAlbumTitlesEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.removeAllBracketsFromAlbumTitlesEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.removeBracketsFromAlbumTitleKeywords)
        defaults.removeObject(forKey: ProSettings.Keys.preventDuplicateScrobblesEnabled)
        defaults.removeObject(forKey: AppSettings.Keys.scrobbleListeningHistoryEnabled)
        defaults.removeObject(forKey: AppSettings.Keys.scrobbleAppleMusicAPIEnabled)
        defaults.removeObject(forKey: AppSettings.Keys.scrobbleOnlyNonLibraryAppleMusicAPITracks)
        defaults.removeObject(forKey: AppSettings.Keys.extendedListeningHistoryScanEnabled)
        defaults.removeObject(forKey: AppSettings.Keys.sendNowPlayingAutomaticallyEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.textReplacementRules)
        AppleMusicRecentTracksImporter.shared.resetState()

        loveOnFavoriteEnabled = false
        scrobbleThresholdIndex = ProSettings.defaultScrobbleThresholdIndex
        preventDuplicateScrobblesEnabled = true
        useAlbumArtistForScrobbling = false
        useFirstArtistOnlyForScrobbling = false
        removeBracketsFromSongTitlesEnabled = false
        removeAllBracketsFromSongTitlesEnabled = false
        removeBracketsFromAlbumTitlesEnabled = false
        removeAllBracketsFromAlbumTitlesEnabled = false
        scrobbleListeningHistoryEnabled = true
        scrobbleAppleMusicAPIEnabled = false
        scrobbleOnlyNonLibraryAppleMusicAPITracks = true
        extendedListeningHistoryScanEnabled = false
        sendNowPlayingAutomaticallyEnabled = true
    }

    @MainActor
    private func scanListeningHistoryTapped() async {
        guard auth.sessionKey != nil else { return }
        guard !isScanningListeningHistory else { return }
        isScanningListeningHistory = true
        defer { isScanningListeningHistory = false }

        let result = await AppModel.shared.runUserInitiatedListeningHistoryScan(
            allowExtendedLookback: true,
            allowSubmissionWhilePaused: true,
            bypassRecentTrackCooldown: true
        )
        if result.totalImportedCount > 0 || result.totalFlushedCount > 0 || result.skippedDuplicateCount > 0 {
            activeAlert = .listeningHistoryScanResult(
                message: String.localizedStringWithFormat(
                    NSLocalizedString("Found %lld new library play(s) and %lld new Apple Music recent track(s).\nSubmitted %lld scrobble(s).\nSkipped %lld already imported play(s).", comment: ""),
                    Int64(result.importedCount),
                    Int64(result.importedRecentTrackCount),
                    Int64(result.totalFlushedCount),
                    Int64(result.skippedDuplicateCount)
                )
            )
        } else if result.recentTracksAuthorizationUnavailable {
            activeAlert = .listeningHistoryScanResult(
                message: NSLocalizedString(
                    "No new library plays found. Apple Music recent tracks could not be checked because Music access is disabled.",
                    comment: ""
                )
            )
        } else if result.recentTracksStatus == .seeded {
            activeAlert = .listeningHistoryScanResult(
                message: NSLocalizedString(
                    "Apple Music recent tracks were initialized from your current history. Future scans will only import newer plays.",
                    comment: ""
                )
            )
        } else if result.recentTracksStatus == .fetchFailed {
            activeAlert = .listeningHistoryScanResult(
                message: NSLocalizedString(
                    "No new library plays found. Apple Music recent tracks could not be checked because the Apple Music API request failed.",
                    comment: ""
                )
            )
        } else {
            activeAlert = .listeningHistoryScanResult(
                message: NSLocalizedString(
                    "No new plays found. Scrobbling from Listening History only works for songs added to your Library.",
                    comment: ""
                )
            )
        }
    }

    @MainActor
    private func connectTapped() async {
        guard !isSigningInToLastFM else { return }
        isSigningInToLastFM = true
        lastFMLoginErrorText = nil
        defer { isSigningInToLastFM = false }

        do {
            try await auth.connect()
            engine.start()
        } catch {
            if error is CancellationError { return }
            lastFMLoginErrorText = error.localizedDescription
        }
    }

    @ViewBuilder
    private func scrobbleThresholdSlider() -> some View {
        let effectiveIndex = pro.isPro ? scrobbleThresholdIndex : ProSettings.defaultScrobbleThresholdIndex
        let percentText = ProSettings.scrobbleThresholdPercentText(index: effectiveIndex)
        let sliderValue = Binding<Double>(
            get: { Double(effectiveIndex) },
            set: {
                guard pro.isPro else { return }
                scrobbleThresholdIndex = Int($0.rounded())
            }
        )

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String.localizedStringWithFormat(localized("Scrobble at %@ of duration"), percentText))
                Spacer()
                lockedProInlineBadge
            }
            .foregroundStyle(pro.isPro ? .primary : .secondary)
            Slider(value: sliderValue, in: 0...Double(ProSettings.scrobbleThresholdOptions.count - 1), step: 1) {
                Text(localized("Scrobble threshold"))
            }
            .disabled(!pro.isPro)
            .tint(proYellow)
            .frame(maxWidth: .infinity)
            HStack {
                Text(localized("10%"))
                Spacer()
                Text(localized("25%"))
                Spacer()
                Text(localized("50%"))
                Spacer()
                Text(localized("75%"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var proUpgradeNavigationRow: some View {
        if pro.isPro {
            NavigationLink(value: SettingsRoute.proUpgrade) {
                Text("View Pro features")
            }
        } else {
            Button {
                navigationPath.append(SettingsRoute.proUpgrade)
            } label: {
                HStack {
                    Text("Upgrade to Pro")
                        .fontWeight(.bold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(proYellow)
        }
    }

    private func removeBracketsNavigationLink(target: RemoveBracketsSettingsPage.Target) -> some View {
        let route: SettingsRoute
        switch target {
        case .songTitles:
            route = .removeBracketsFromSongTitles
        case .albumTitles:
            route = .removeBracketsFromAlbumTitles
        }
        return NavigationLink(value: route) {
            HStack {
                Text(target.settingsLabel)
                Spacer()
                proFeatureBadgePlaceholder
            }
        }
        .overlay(alignment: .trailing) {
            lockedProBadgeOverlay(trailingInset: Self.iosLockedProNavigationBadgeTrailingInset)
        }
    }

    @ViewBuilder
    private var appleMusicAPINavigationLink: some View {
        NavigationLink(value: SettingsRoute.appleMusicAPI) {
            Text(localized("Scrobble from Apple Music API"))
        }
    }

    @ViewBuilder
    private var textReplacementNavigationLink: some View {
        NavigationLink(value: SettingsRoute.textReplacement) {
            HStack {
                Text(localized("Text replacement"))
                    .foregroundStyle(pro.isPro ? .primary : .secondary)
                Spacer()
                proFeatureBadgePlaceholder
            }
        }
        .disabled(!pro.isPro)
        .overlay(alignment: .trailing) {
            lockedProBadgeOverlay(trailingInset: Self.iosLockedProNavigationBadgeTrailingInset)
        }
    }

    private var appStorageNavigationLink: some View {
        NavigationLink(value: SettingsRoute.appStorage) {
            Label("App Storage", systemImage: "externaldrive")
        }
        .foregroundStyle(.red)
    }

    @ViewBuilder
    private var lockedProInlineBadge: some View {
        if !pro.isPro {
            ProFeatureBadge()
        }
    }

    @ViewBuilder
    private var proFeatureBadgePlaceholder: some View {
        // Invisible badge reserves the same trailing space so row content stays
        // left-aligned regardless of Pro status, avoiding layout shifts.
        if !pro.isPro {
            ProFeatureBadge()
                .hidden()
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func lockedProBadgeOverlay(trailingInset: CGFloat) -> some View {
        if !pro.isPro {
            ProFeatureBadge()
                .allowsHitTesting(false)
                .padding(.trailing, trailingInset)
        }
    }

    private func iosLinksBrandButton(title: LocalizedStringKey, imageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            settingsBrandLabel(title: title, imageName: imageName, color: .white)
        }
        .listRowBackground(Self.linksSectionRed)
        .listRowSeparatorTint(.white.opacity(0.35))
    }

    private func iosLinksButton(title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.white)
        }
        .listRowBackground(Self.linksSectionRed)
        .listRowSeparatorTint(.white.opacity(0.35))
    }

    private func settingsBrandLabel(title: LocalizedStringKey, imageName: String, color: Color, iconSize: CGFloat = 24) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(imageName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .frame(width: iconSize + 5, alignment: .center)
        }
        .foregroundStyle(color)
    }

    // Returns a binding that reads/writes the real storage only when Pro is active;
    // non-Pro users always see unlockedDefault and writes are silently dropped.
    private func proLockedBoolBinding(_ storage: Binding<Bool>, unlockedDefault: Bool) -> Binding<Bool> {
        Binding(
            get: { pro.isPro ? storage.wrappedValue : unlockedDefault },
            set: { newValue in
                guard pro.isPro else { return }
                storage.wrappedValue = newValue
            }
        )
    }
}

private struct AppStorageSettingsPage: View {
    @ObservedObject private var iCloudSync = ICloudSyncCoordinator.shared
    @State private var isRunningStorageMaintenance = false
    @State private var storageUsageSnapshot: StorageUsageSnapshot?
    @State private var storageMaintenanceAlertMessage: String?
    @State private var isConfirmingICloudDeletion = false
    @State private var isDebugUnlocked = false

    private var canDeleteICloudData: Bool {
        !iCloudSync.isBusy && (iCloudSync.isSyncEnabled || iCloudSync.hasCloudData)
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await runStorageMaintenanceTapped() }
                } label: {
                    Label(
                        isRunningStorageMaintenance ? localized("Cleaning Up…") : localized("Trim Local Storage"),
                        systemImage: "externaldrive.badge.timemachine"
                    )
                }
                .disabled(isRunningStorageMaintenance)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { iCloudSync.isSyncEnabled },
                    set: { newValue in
                        Task { await setICloudSyncEnabled(newValue) }
                    }
                )) {
                    Text(localized("Sync with iCloud"))
                }
                .disabled(iCloudSync.isBusy || (!iCloudSync.isICloudAvailable && !iCloudSync.isSyncEnabled))

                Button {
                    isConfirmingICloudDeletion = true
                } label: {
                    Label(localized("Delete iCloud Data"), systemImage: "trash")
                        .foregroundStyle(canDeleteICloudData ? .red : .secondary)
                }
                .disabled(!canDeleteICloudData)
            } header: {
                Text(localized("iCloud Sync"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("Back up your FastScrobbler data to iCloud and keep it synced across your devices."))

                    if !iCloudSync.isICloudAvailable {
                        Text(localized("iCloud is currently unavailable on this device."))
                    } else if iCloudSync.isBusy {
                        Text(localized("Working…"))
                    } else if let error = iCloudSync.lastErrorMessage, !error.isEmpty {
                        Text(error)
                    } else if let status = iCloudSync.statusMessage, !status.isEmpty {
                        Text(status)
                    }
                }
            }

            Section {
                storageUsageRow(title: "Backlog items", value: storageUsageSnapshot.map { "\($0.backlogCount)" })
                storageUsageRow(title: "Backlog storage", value: storageUsageSnapshot.map { byteCountText($0.backlogBytes) })
                storageUsageRow(title: "Scrobble log entries", value: storageUsageSnapshot.map { "\($0.scrobbleLogCount)" })
                storageUsageRow(title: "Scrobble log storage", value: storageUsageSnapshot.map { byteCountText($0.scrobbleLogBytes) })
                storageUsageRow(title: "Listening history state", value: storageUsageSnapshot.map { byteCountText($0.playbackHistoryStateBytes) })
                storageUsageRow(
                    title: "Recent tracks state",
                    value: storageUsageSnapshot.map { byteCountText($0.recentTracksStateBytes) }
                ) {
                    isDebugUnlocked = true
                }
            } footer: {
                Text(localized("FastScrobbler stores these data to optimise your scrobbling experience. FastScrobbler does NOT store these for data collection purposes."))
            }

            if isDebugUnlocked {
                Section {
                    NavigationLink(value: SettingsView.SettingsRoute.debug) {
                        Text("Debug")
                    }
                }
            }
        }
        .navigationTitle(localized("App Storage"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshStorageUsageSnapshot()
            await iCloudSync.refreshStatus()
        }
        .alert(localized("App Storage"), isPresented: Binding(
            get: { storageMaintenanceAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    storageMaintenanceAlertMessage = nil
                }
            }
        )) {
            Button(localized("OK"), role: .cancel) {}
        } message: {
            Text(storageMaintenanceAlertMessage ?? "")
        }
        .alert(localized("Delete iCloud Data?"), isPresented: $isConfirmingICloudDeletion) {
            Button(localized("Delete iCloud Data"), role: .destructive) {
                Task { await deleteICloudDataTapped() }
            }
            Button(localized("Cancel"), role: .cancel) {}
        } message: {
            Text(localized("This removes only the iCloud copy of your synced FastScrobbler data. Local data on this iPhone stays intact, and iCloud sync will be turned off here."))
        }
    }

    @MainActor
    private func runStorageMaintenanceTapped() async {
        guard !isRunningStorageMaintenance else { return }
        isRunningStorageMaintenance = true
        defer { isRunningStorageMaintenance = false }

        await AppModel.shared.runStorageMaintenanceNow()
        await refreshStorageUsageSnapshot()
        storageMaintenanceAlertMessage = localized("Local storage cleanup finished.")
    }

    @MainActor
    private func refreshStorageUsageSnapshot() async {
        storageUsageSnapshot = await AppModel.shared.collectStorageUsageSnapshot()
    }

    @MainActor
    private func setICloudSyncEnabled(_ isEnabled: Bool) async {
        if isEnabled {
            do {
                try await iCloudSync.enableSync()
            } catch {
                storageMaintenanceAlertMessage = error.localizedDescription
            }
        } else {
            await iCloudSync.disableSync()
        }
    }

    @MainActor
    private func deleteICloudDataTapped() async {
        do {
            try await iCloudSync.deleteCloudData()
        } catch {
            storageMaintenanceAlertMessage = error.localizedDescription
        }
    }

    private func storageUsageRow(title: String, value: String?, titleTapAction: (() -> Void)? = nil) -> some View {
        HStack {
            if let titleTapAction {
                Text(localized(title))
                    .onTapGesture(count: 3, perform: titleTapAction)
            } else {
                Text(localized(title))
            }
            Spacer()
            Text(value ?? localized("Loading…"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func byteCountText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

private struct DebugSettingsPage: View {
    var body: some View {
        Form {
            Section {
                Button(role: .destructive) {
                    fatalError("Crashlytics test crash")
                } label: {
                    Label("Test Crashlytics", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProFeatureBadge: View {
    var body: some View {
        Text("Pro")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(proYellow)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("Pro")
    }
}
