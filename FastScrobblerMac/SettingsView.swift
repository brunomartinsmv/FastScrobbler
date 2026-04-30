import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private static let repositoryURL = URL(string: "https://github.com/kevinlim512/FastScrobbler")!
    private static let redditURL = URL(string: "https://www.reddit.com/r/FastScrobbler/")!
    private static let redditSubmitURL = URL(string: "https://www.reddit.com/r/FastScrobbler/submit")!
    private static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6759501541?action=write-review")!
    // Last.fm brand red, used for the links section background
    private static let linksSectionRed = Color(red: 0.72, green: 0.14, blue: 0.14)
    private static let macSettingsButtonMinHeight: CGFloat = 28

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    @AppStorage(ProSettings.Keys.loveOnFavoriteEnabled, store: AppGroup.userDefaults) private var loveOnFavoriteEnabled = false
    @AppStorage(ProSettings.Keys.scrobbleThresholdIndex, store: AppGroup.userDefaults) private var scrobbleThresholdIndex = ProSettings.defaultScrobbleThresholdIndex
    @AppStorage(ProSettings.Keys.useAlbumArtistForScrobbling, store: AppGroup.userDefaults) private var useAlbumArtistForScrobbling = false
    @AppStorage(ProSettings.Keys.removeBracketsFromSongTitlesEnabled, store: AppGroup.userDefaults) private var removeBracketsFromSongTitlesEnabled = false
    @AppStorage(ProSettings.Keys.removeAllBracketsFromSongTitlesEnabled, store: AppGroup.userDefaults) private var removeAllBracketsFromSongTitlesEnabled = false
    @AppStorage(ProSettings.Keys.removeBracketsFromAlbumTitlesEnabled, store: AppGroup.userDefaults) private var removeBracketsFromAlbumTitlesEnabled = false
    @AppStorage(ProSettings.Keys.removeAllBracketsFromAlbumTitlesEnabled, store: AppGroup.userDefaults) private var removeAllBracketsFromAlbumTitlesEnabled = false
    @AppStorage(ProSettings.Keys.preventDuplicateScrobblesEnabled, store: AppGroup.userDefaults) private var preventDuplicateScrobblesEnabled = true
    @AppStorage(AppSettings.Keys.scrobbleListeningHistoryEnabled, store: AppGroup.userDefaults) private var scrobbleListeningHistoryEnabled = true

    @EnvironmentObject private var auth: LastFMAuthManager
    @EnvironmentObject private var engine: ScrobbleEngine
    @EnvironmentObject private var pro: ProPurchaseManager
    @EnvironmentObject private var appLanguage: AppLanguageStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private enum ActiveAlert: Identifiable {
        case logoutConfirmation
        case resetConfirmation

        var id: String {
            switch self {
            case .logoutConfirmation:
                return "logoutConfirmation"
            case .resetConfirmation:
                return "resetConfirmation"
            }
        }
    }

    private enum SettingsRoute: Hashable {
        case removeBracketsFromSongTitles
        case removeBracketsFromAlbumTitles
        case textReplacement
    }

    @State private var activeAlert: ActiveAlert?
    @State private var isSigningInToLastFM = false
    @State private var lastFMLoginErrorText: String?
    @State private var startAtLoginEnabled = StartAtLoginManager.isEnabled
    @State private var startAtLoginErrorText: String?
    @State private var isConfirmingReset = false
    @State private var isConfirmingSignOut = false

    let onBack: (() -> Void)?

    init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
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
                    }
                }
        }
        .task {
            await auth.refreshUserInfoIfNeeded()
            startAtLoginEnabled = StartAtLoginManager.isEnabled
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
    }

    @ViewBuilder
    private var settingsRootContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(localized("Settings"))
                    .font(.title.weight(.bold))

                macGeneralCard
                macScrobbleControlsCard
                macAccountCard
                macSupportCard
            }
            .padding()
            .padding(.top, MacFloatingBarLayout.contentTopPadding)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            if onBack != nil {
                MacFloatingCircleButton(
                    systemImage: "chevron.left",
                    help: "Back",
                    accessibilityLabel: "Back",
                    action: {
                        if let onBack {
                            onBack()
                        } else {
                            dismiss()
                        }
                    }
                )
                .padding(.top, 10)
                .padding(.leading, 10)
            }
        }
    }

    private var macGeneralCard: some View {
        let requiresApproval = (StartAtLoginManager.status == .requiresApproval)
        return VStack(alignment: .leading, spacing: 12) {
            Text(localized("General"))
                .font(.title3.weight(.semibold))

            HStack(alignment: .center, spacing: -20) {
                Text(localized("Language"))
                Picker(localized("Language"), selection: $appLanguage.selection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 180)
            }
            .fixedSize()

            Toggle(localized("Start at login"), isOn: $startAtLoginEnabled)
                .onValueChange(of: startAtLoginEnabled) { isEnabled in
                    Task { @MainActor in
                        do {
                            try StartAtLoginManager.setEnabled(isEnabled)
                        } catch {
                            startAtLoginErrorText = error.localizedDescription
                        }
                        startAtLoginEnabled = StartAtLoginManager.isEnabled
                    }
                }

            Text(
                requiresApproval
                    ? NSLocalizedString("Requires approval in System Settings → Login Items.", comment: "")
                    : NSLocalizedString("Launches FastScrobbler when you sign in.", comment: "")
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
        .alert(localized("Couldn't update Start at login"), isPresented: Binding(
            get: { startAtLoginErrorText != nil },
            set: { isPresented in
                if !isPresented {
                    startAtLoginErrorText = nil
                }
            }
        )) {
            Button(localized("OK"), role: .cancel) {}
        } message: {
            Text(startAtLoginErrorText ?? "")
        }
    }

    private var macScrobbleControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("Scrobble Controls"))
                .font(.title3.weight(.semibold))

            Toggle(localized("Prevent duplicate scrobbles"), isOn: $preventDuplicateScrobblesEnabled)
            Text(localized("Avoids sending the same playback session to Last.fm more than once within a short time window."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            scrobbleThresholdSlider()
            removeBracketsNavigationLink(target: .songTitles)
            removeBracketsNavigationLink(target: .albumTitles)
            textReplacementNavigationLink
            Toggle(isOn: proLockedBoolBinding($loveOnFavoriteEnabled, unlockedDefault: false)) {
                HStack {
                    Text(localized("Love Apple Music favourites on Last.fm"))
                        .foregroundStyle(pro.isPro ? .primary : .secondary)
                    Spacer()
                    ProFeatureBadge()
                }
            }
            .disabled(!pro.isPro)
            Toggle(isOn: proLockedBoolBinding($useAlbumArtistForScrobbling, unlockedDefault: false)) {
                HStack {
                    Text(localized("Replace song artist with album artist when scrobbling"))
                        .foregroundStyle(pro.isPro ? .primary : .secondary)
                    Spacer()
                    ProFeatureBadge()
                }
            }
            .disabled(!pro.isPro)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    private var macAccountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(localized("Account"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(auth.sessionKey != nil ? NSLocalizedString("Connected", comment: "") : NSLocalizedString("Not connected", comment: ""))
                    .foregroundStyle(auth.sessionKey != nil ? .green : .secondary)
            }

            if auth.sessionKey != nil {
                HStack {
                    Text(localized("Username"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(auth.username ?? NSLocalizedString("Loading…", comment: ""))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .font(.subheadline)
            }

            HStack(spacing: 12) {
                if !isConfirmingSignOut {
                    Button {
                        if let url = auth.freshProfileURL() {
                            openURL(url)
                        }
                    } label: {
                        Label(localized("View Profile"), systemImage: "person.circle")
                            .frame(maxWidth: .infinity, minHeight: Self.macSettingsButtonMinHeight)
                    }
                    .buttonStyle(.bordered)
                    .pillButtonBorder()
                    .disabled(auth.sessionKey == nil || auth.profileURL == nil)
                }

                if auth.sessionKey == nil {
                    Button {
                        Task { await connectTapped() }
                    } label: {
                        Label(isSigningInToLastFM ? NSLocalizedString("Signing In…", comment: "") : NSLocalizedString("Sign In", comment: ""), systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity, minHeight: Self.macSettingsButtonMinHeight)
                    }
                    .buttonStyle(.bordered)
                    .pillButtonBorder()
                    .tint(.blue)
                    .disabled(isSigningInToLastFM)
                } else {
                    if isConfirmingSignOut {
                        HStack(spacing: 8) {
                            Text("Sign out?")
                                .foregroundStyle(.secondary)
                                .font(.headline)
                            Spacer()
                            Button("Cancel") {
                                isConfirmingSignOut = false
                            }
                            .buttonStyle(.bordered)
                            .pillButtonBorder()
                            Button("Sign Out") {
                                isConfirmingSignOut = false
                                performLogout()
                            }
                            .buttonStyle(.borderedProminent)
                            .pillButtonBorder()
                            .tint(.red)
                        }
                        .frame(minHeight: Self.macSettingsButtonMinHeight)
                    } else {
                        Button {
                            isConfirmingSignOut = true
                        } label: {
                            Label(localized("Sign Out"), systemImage: "power")
                                .frame(maxWidth: .infinity, minHeight: Self.macSettingsButtonMinHeight)
                        }
                        .buttonStyle(.bordered)
                        .pillButtonBorder()
                        .tint(.red)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    private var macSupportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 12) {
                macRedditButton
                macAskQuestionButton
                macRateButton
                macGitHubButton
                macResetButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    private func performLogout() {
        auth.disconnect()
        engine.setUserPaused(false)
        engine.stop()
    }

    private func resetToInitialSettings() {
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
        defaults.removeObject(forKey: AppSettings.Keys.extendedListeningHistoryScanEnabled)
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

        appLanguage.selection = .system
        Task { @MainActor in
            do {
                try StartAtLoginManager.setEnabled(false)
            } catch {
                startAtLoginErrorText = error.localizedDescription
            }
            startAtLoginEnabled = StartAtLoginManager.isEnabled
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
            Slider(value: sliderValue, in: 0...Double(ProSettings.scrobbleThresholdOptions.count - 1), step: 1)
                .disabled(!pro.isPro)
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
            HStack(spacing: 12) {
                Text(target.settingsLabel)
                    .foregroundStyle(pro.isPro ? .primary : .secondary)
                Spacer()
                ProFeatureBadge()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!pro.isPro)
    }

    @ViewBuilder
    private var textReplacementNavigationLink: some View {
        NavigationLink(value: SettingsRoute.textReplacement) {
            HStack(spacing: 12) {
                Text(localized("Text replacement"))
                    .foregroundStyle(pro.isPro ? .primary : .secondary)
                Spacer()
                ProFeatureBadge()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!pro.isPro)
    }

    @ViewBuilder
    private var lockedProInlineBadge: some View {
        if !pro.isPro {
            ProFeatureBadge()
        }
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

    private var macRedditButton: some View {
        Button {
            openURL(Self.redditURL)
        } label: {
            settingsBrandLabel(title: "r/FastScrobbler", imageName: "reddit_logo", color: .white, iconSize: 16)
                .frame(maxWidth: .infinity, minHeight: Self.macSettingsButtonMinHeight)
        }
        .buttonStyle(.borderedProminent)
        .pillButtonBorder()
        .tint(Self.linksSectionRed)
    }

    private var macAskQuestionButton: some View {
        Button {
            openURL(Self.redditSubmitURL)
        } label: {
            Label("Ask a Question or Report a Bug", systemImage: "questionmark.bubble")
                .frame(maxWidth: .infinity, minHeight: Self.macSettingsButtonMinHeight)
        }
        .buttonStyle(.borderedProminent)
        .pillButtonBorder()
        .tint(Self.linksSectionRed)
    }

    private var macRateButton: some View {
        Button {
            openURL(Self.writeReviewURL)
        } label: {
            Label("Rate FastScrobbler", systemImage: "star.bubble")
                .frame(maxWidth: .infinity, minHeight: Self.macSettingsButtonMinHeight)
        }
        .buttonStyle(.borderedProminent)
        .pillButtonBorder()
        .tint(Self.linksSectionRed)
    }

    private var macGitHubButton: some View {
        Button {
            openURL(Self.repositoryURL)
        } label: {
            settingsBrandLabel(title: "GitHub", imageName: "github_logo", color: .white, iconSize: 16)
                .frame(maxWidth: .infinity, minHeight: Self.macSettingsButtonMinHeight)
        }
        .buttonStyle(.borderedProminent)
        .pillButtonBorder()
        .tint(Self.linksSectionRed)
    }

    private var macResetButton: some View {
        Group {
            if isConfirmingReset {
                HStack(spacing: 8) {
                    Text("Reset settings?")
                        .foregroundStyle(.secondary)
                        .font(.headline)
                    Spacer()
                    Button("Cancel") {
                        isConfirmingReset = false
                    }
                    .buttonStyle(.bordered)
                    .pillButtonBorder()
                    Button("Reset") {
                        isConfirmingReset = false
                        resetToInitialSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .pillButtonBorder()
                    .tint(.red)
                }
                .frame(minHeight: Self.macSettingsButtonMinHeight)
            } else {
                Button {
                    isConfirmingReset = true
                } label: {
                    Label("Reset Settings", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: Self.macSettingsButtonMinHeight)
                }
                .buttonStyle(.bordered)
                .pillButtonBorder()
                .tint(.red)
            }
        }
    }

    private enum StartAtLoginManager {
        static var status: SMAppService.Status {
            SMAppService.mainApp.status
        }

        // .requiresApproval counts as "enabled" because the user already toggled it on;
        // macOS just hasn't granted final permission yet.
        static var isEnabled: Bool {
            switch status {
            case .enabled, .requiresApproval:
                return true
            default:
                return false
            }
        }

        static func setEnabled(_ enabled: Bool) throws {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}

struct ProFeatureBadge: View {
    var body: some View {
        EmptyView()
    }
}
