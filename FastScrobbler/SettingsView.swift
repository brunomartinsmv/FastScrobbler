import SwiftUI
#if os(iOS)
import ActivityKit
#endif

struct SettingsView: View {
    private static let repositoryURL = URL(string: "https://github.com/kevinlim512/FastScrobbler")!
    private static let redditURL = URL(string: "https://www.reddit.com/r/FastScrobbler/")!
    private static let redditSubmitURL = URL(string: "https://www.reddit.com/r/FastScrobbler/submit")!
    private static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6759501541?action=write-review")!
    // Last.fm brand red, used for the links section background
    private static let linksSectionRed = Color(red: 0.72, green: 0.14, blue: 0.14)
    // Insets position the Pro badge overlay to sit just inside the disclosure indicator / toggle
    private static let iosLockedProNavigationBadgeTrailingInset: CGFloat = 24
    private static let iosLockedProToggleBadgeTrailingInset: CGFloat = 63

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    @AppStorage(LiveActivityManager.enabledDefaultsKey) private var liveActivityEnabled = false
    @AppStorage(ProSettings.Keys.loveOnFavoriteEnabled, store: AppGroup.userDefaults) private var loveOnFavoriteEnabled = false
    @AppStorage(ProSettings.Keys.scrobbleThresholdIndex, store: AppGroup.userDefaults) private var scrobbleThresholdIndex = ProSettings.defaultScrobbleThresholdIndex
    @AppStorage(ProSettings.Keys.useAlbumArtistForScrobbling, store: AppGroup.userDefaults) private var useAlbumArtistForScrobbling = false
    @AppStorage(ProSettings.Keys.removeBracketsFromSongTitlesEnabled, store: AppGroup.userDefaults) private var removeBracketsFromSongTitlesEnabled = false
    @AppStorage(ProSettings.Keys.removeAllBracketsFromSongTitlesEnabled, store: AppGroup.userDefaults) private var removeAllBracketsFromSongTitlesEnabled = false
    @AppStorage(ProSettings.Keys.removeBracketsFromAlbumTitlesEnabled, store: AppGroup.userDefaults) private var removeBracketsFromAlbumTitlesEnabled = false
    @AppStorage(ProSettings.Keys.removeAllBracketsFromAlbumTitlesEnabled, store: AppGroup.userDefaults) private var removeAllBracketsFromAlbumTitlesEnabled = false
    @AppStorage(ProSettings.Keys.preventDuplicateScrobblesEnabled, store: AppGroup.userDefaults) private var preventDuplicateScrobblesEnabled = true
    @AppStorage(AppSettings.Keys.scrobbleListeningHistoryEnabled, store: AppGroup.userDefaults) private var scrobbleListeningHistoryEnabled = true
    @AppStorage(ProSettings.Keys.scrobbleListeningHistoryFromAllDevicesEnabled, store: AppGroup.userDefaults) private var scrobbleListeningHistoryFromAllDevicesEnabled = false

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

    private enum SettingsRoute: Hashable {
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

    var isShowingHelp: Binding<Bool>?

    init(isShowingHelp: Binding<Bool>? = nil) {
        self.isShowingHelp = isShowingHelp
    }

    var body: some View {
        NavigationStack {
            settingsRootContent
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
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
#if os(iOS)
                .navigationBarTitleDisplayMode(.large)
#endif
                .toolbar {
                    if !isEmbeddedInTab {
#if os(iOS)
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                dismiss()
                            } label: {
                                IOSCloseButtonLabel(style: .plain)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close")
                        }
#endif
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
#if os(iOS)
        .fullScreenCover(isPresented: $isShowingWhatsNew) {
            WhatsNewView {
                isShowingWhatsNew = false
            }
        }
#else
        .sheet(isPresented: $isShowingWhatsNew) {
            WhatsNewView {
                isShowingWhatsNew = false
            }
        }
#endif
    }

    @ViewBuilder
    private var settingsRootContent: some View {
        Form {
            Section(pro.isPro ? "Thank you! ^_^" : "Unlock Pro features") {
                NavigationLink(value: SettingsRoute.proUpgrade) {
                    Text(pro.isPro ? "View Pro features" : "Upgrade to Pro")
                        .fontWeight(pro.isPro ? .regular : .bold)
                        .foregroundStyle(.primary)
                        .padding(.vertical, pro.isPro ? 0 : 10)
                }
                .listRowBackground(pro.isPro ? nil : Color.yellow)
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
#if os(iOS)
                .listSectionSpacing(.compact)
#endif
            }

            Section("Scrobble Controls") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Prevent duplicate scrobbles", isOn: $preventDuplicateScrobblesEnabled)
                    Text("Avoids sending the same playback session to Last.fm more than once within a short time window.")
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
                .tint(.yellow)
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
                .tint(.yellow)
                .overlay(alignment: .trailing) {
                    lockedProBadgeOverlay(trailingInset: Self.iosLockedProToggleBadgeTrailingInset)
                }
            }

            Section("Listening History") {
                let allDevicesEnabled = scrobbleListeningHistoryEnabled && pro.isPro

                Button {
                    Task { await scanListeningHistoryTapped() }
                } label: {
                    Label(
                        isScanningListeningHistory ? NSLocalizedString("Scanning…", comment: "") : NSLocalizedString("Scan Listening History", comment: ""),
                        systemImage: "clock.arrow.circlepath"
                    )
                    .foregroundStyle(auth.sessionKey != nil && scrobbleListeningHistoryEnabled ? .primary : .secondary)
                }
                .padding(.vertical, 8)
                .disabled(auth.sessionKey == nil || isScanningListeningHistory || !scrobbleListeningHistoryEnabled)

                Text(
                    scrobbleListeningHistoryEnabled
                        ? String.localizedStringWithFormat(
                            NSLocalizedString("Imports plays from your Music app Listening History (%@).", comment: ""),
                            allDevicesEnabled
                                ? NSLocalizedString("all devices", comment: "")
                                : NSLocalizedString("this device only", comment: "")
                        )
                        : NSLocalizedString("Listening History scrobbling is turned off.", comment: "")
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
                    // Hardcoded to true and disabled while the multi-device scrobble feature is broken
                    Toggle(isOn: .constant(true)) {
                        Text("Scrobble Listening History from all devices")
                            .foregroundStyle(.secondary)
                    }
                    .disabled(true)

                    Text(NSLocalizedString("This toggle is currently unavailable due to issues affecting the reliability of scrobbling from Listening History.", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Live Activity") {
                Toggle("Show Live Activity (Beta)", isOn: $liveActivityEnabled)
                    .onValueChange(of: liveActivityEnabled) { isEnabled in
                        if isEnabled {
                            LiveActivityManager.shared.startIfPossible()
                        } else {
                            Task { @MainActor in
                                await LiveActivityManager.shared.stop()
                            }
                        }
                    }

                #if os(iOS)
                if #available(iOS 16.1, *) {
                    if !ActivityAuthorizationInfo().areActivitiesEnabled {
                        Text("Live Activities are disabled in iOS Settings for FastScrobbler.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif

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
        liveActivityEnabled = false
        Task { @MainActor in
            await LiveActivityManager.shared.stop()
        }

        let defaults = AppGroup.userDefaults
        defaults.removeObject(forKey: ProSettings.Keys.loveOnFavoriteEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.scrobbleThresholdIndex)
        defaults.removeObject(forKey: ProSettings.Keys.useAlbumArtistForScrobbling)
        defaults.removeObject(forKey: ProSettings.Keys.removeBracketsFromSongTitlesEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.removeAllBracketsFromSongTitlesEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.removeBracketsFromSongTitleKeywords)
        defaults.removeObject(forKey: ProSettings.Keys.removeBracketsFromAlbumTitlesEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.removeAllBracketsFromAlbumTitlesEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.removeBracketsFromAlbumTitleKeywords)
        defaults.removeObject(forKey: ProSettings.Keys.preventDuplicateScrobblesEnabled)
        defaults.removeObject(forKey: AppSettings.Keys.scrobbleListeningHistoryEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.scrobbleListeningHistoryFromAllDevicesEnabled)
        defaults.removeObject(forKey: ProSettings.Keys.textReplacementRules)

        loveOnFavoriteEnabled = false
        scrobbleThresholdIndex = ProSettings.defaultScrobbleThresholdIndex
        preventDuplicateScrobblesEnabled = true
        useAlbumArtistForScrobbling = false
        removeBracketsFromSongTitlesEnabled = false
        removeAllBracketsFromSongTitlesEnabled = false
        removeBracketsFromAlbumTitlesEnabled = false
        removeAllBracketsFromAlbumTitlesEnabled = false
        scrobbleListeningHistoryEnabled = true
        scrobbleListeningHistoryFromAllDevicesEnabled = false
    }

    @MainActor
    private func scanListeningHistoryTapped() async {
        guard auth.sessionKey != nil else { return }
        guard !isScanningListeningHistory else { return }
        isScanningListeningHistory = true
        defer { isScanningListeningHistory = false }

        let result = await AppModel.shared.scanListeningHistory()
        if result.dialogCount > 0 {
            activeAlert = .listeningHistoryScanResult(
                message: String.localizedStringWithFormat(
                    NSLocalizedString("Imported %lld play(s).", comment: ""),
                    Int64(result.dialogCount)
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
            .tint(.yellow)
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

struct ProFeatureBadge: View {
    var body: some View {
        Text("Pro")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.yellow)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("Pro")
    }
}
