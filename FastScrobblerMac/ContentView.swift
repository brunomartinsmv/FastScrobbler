#if canImport(MediaPlayer)
import MediaPlayer
#endif
import SwiftUI

struct ContentView: View {
    private enum Keys {
        static let hasSeenSetup = "FastScrobbler.Setup.hasSeen"
    }

    @EnvironmentObject private var auth: LastFMAuthManager
    @EnvironmentObject private var observer: AppleMusicNowPlayingObserver
    @EnvironmentObject private var engine: ScrobbleEngine
    @EnvironmentObject private var scrobbleLog: ScrobbleLogStore
    @EnvironmentObject private var permissions: PermissionStatusStore
    @EnvironmentObject private var pro: ProPurchaseManager

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(Keys.hasSeenSetup) private var hasSeenSetup = false

    @State private var currentDate: Date = .now
    // See iOS ContentView — secondTick drives per-second re-renders of time-sensitive views.
    @State private var secondTick: Int = 0
    @State private var lastScrobbleLogRefreshDate: Date = .distantPast
    @State private var errorText: String?
    @State private var isShowingSetup = false
    @State private var isShowingWhatsNew = false
    @State private var isShowingHelp = false
    @State private var isShowingSettings = false
    @State private var isShowingManualScrobble = false

    var body: some View {
        Group {
            // NavigationStack avoids the two-column split layout NavigationView produces on macOS.
            NavigationStack {
                mainContent
            }
        }
        // scenePhase doesn't fire reliably for popover-style menu bar apps, so we refresh
        // permissions each time the popover is about to become visible instead.
        .onReceive(NotificationCenter.default.publisher(for: .fastScrobblerPopoverWillShow)) { _ in
            refreshScrobbleLogDisplay(now: .now, forceReload: true)
            refreshPermissionStatusesIfNeeded()
        }
        .onAppear {
            refreshScrobbleLogDisplay(now: .now, forceReload: true)
            refreshPermissionStatusesIfNeeded()
            presentWhatsNewIfNeeded()
        }
        .onValueChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            refreshScrobbleLogDisplay(now: .now, forceReload: true)
            refreshPermissionStatusesIfNeeded()
            presentWhatsNewIfNeeded()
        }
        .onValueChange(of: observer.authorizationStatus) { _ in
            refreshPermissionStatusesIfNeeded()
        }
        .onValueChange(of: hasSeenSetup) { hasSeenSetup in
            guard hasSeenSetup else { return }
            presentWhatsNewIfNeeded()
        }
        .overlay {
            macModalOverlay
        }
    }

    private var mainContent: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    macAttentionBanner
                    controls
                    statusCard
                    trackCard
                    scrobbleLogCard
                    if let errorText {
                        Text(errorText)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
                .padding()
                .padding(.top, -8)
                        .padding(.top, MacFloatingBarLayout.contentTopPadding) // room for the floating capsule bar
                .animation(.easeInOut(duration: 0.3), value: observer.track)
                .animation(.easeInOut(duration: 0.3), value: auth.sessionKey != nil)
                .animation(.easeInOut(duration: 0.3), value: engine.statusText)
            }

            macPopoverTopButtons
                .padding(.top, 10)
                .padding(.trailing, 10)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            handleTimerTick(now: .now)
        }
        .navigationTitle("")
        .toolbar {}
    }

    private var macPopoverTopButtons: some View {
        MacCapsuleBar {
            HStack(spacing: 10) {
                Button {
                    isShowingHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(6)
                }
                .help("Help")
                .accessibilityLabel("Help")

                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(6)
                }
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
    }

    private var statusCard: some View {
        let _ = secondTick
        return VStack(alignment: .leading, spacing: 8) {
            Text("Last.fm")
                .font(.title2.weight(.semibold))
            if auth.sessionKey != nil {
                Text("Connected").foregroundColor(.green)
            } else {
                Text("Not connected").foregroundColor(.secondary)
            }
            engineStatusText(engine.statusText)
                .font(.footnote)
        }
        .animation(.easeInOut(duration: 0.3), value: auth.sessionKey != nil)
        .animation(.easeInOut(duration: 0.3), value: engine.statusText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    private var trackCard: some View {
        let _ = secondTick
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Now Playing")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            if let t = observer.track {
                Text("\(t.artist) - \(t.title)")
                if let album = t.album, !album.isEmpty {
                    Text(album)
                }
                if let d = t.durationSeconds, d > 0 {
                    let progress = min(observer.playbackTimeSeconds / d, 1.0)
                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 6)
                                Capsule()
                                    .fill(Color.primary.opacity(0.8))
                                    .frame(width: geo.size.width * progress, height: 6)
                                let thresholdX = geo.size.width * ProSettings.scrobbleThresholdFraction()
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: 3, height: 10)
                                    .offset(x: thresholdX - 1.5)
                            }
                        }
                        .frame(height: 6)
                        HStack {
                            Text(formatTime(observer.playbackTimeSeconds))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatTime(d))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 12)
                }
            } else {
                Text("No track detected.")
            }
        }
        .animation(.easeInOut(duration: 0.3), value: observer.track)
        .animation(.easeInOut(duration: 0.3), value: observer.playbackState)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    private var controls: some View {
        let actionButtonHeight: CGFloat = 32
        let actionButtonSpacing: CGFloat = 12

        return VStack(spacing: 12) {
            Button {
                if let url = URL(string: "music://") {
                    openURL(url)
                }
            } label: {
                Label(NSLocalizedString("Open Music App", comment: ""), systemImage: "music.note")
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: actionButtonHeight)
            }
            .buttonStyle(.borderedProminent)
            .pillButtonBorder()
            .tint(.red)
            .buttonGlow(.red)
            .padding(.top, 8)

            HStack(spacing: actionButtonSpacing) {
                Button {
                    engine.setUserPaused(!engine.isUserPaused)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: engine.isUserPaused ? "play.fill" : "pause.fill")
                        Text(engine.isUserPaused ? NSLocalizedString("Resume", comment: "") : NSLocalizedString("Pause", comment: ""))
                    }
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: actionButtonHeight)
                }
                .buttonStyle(.borderedProminent)
                .pillButtonBorder()
                .tint(engine.isUserPaused ? .green : .orange)
                .buttonGlow(engine.isUserPaused ? .green : .orange)
                .disabled(auth.sessionKey == nil)

                if auth.sessionKey == nil {
                    Button {
                        Task { await connectTapped() }
                    } label: {
                        Label(NSLocalizedString("Sign In", comment: ""), systemImage: "person.crop.circle")
                            .font(.body.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: actionButtonHeight)
                    }
                    .buttonStyle(.borderedProminent)
                    .pillButtonBorder()
                    .tint(.blue)
                    .buttonGlow(.blue)
                } else {
                    Button {
                        Task { await engine.scrobbleNow(force: true) }
                    } label: {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "memories.badge.plus")
                            Text(NSLocalizedString("Scrobble Now", comment: ""))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.6)
                                .allowsTightening(true)
                        }
                        .font(.body.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: actionButtonHeight, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .pillButtonBorder()
                    .tint(.purple)
                    .buttonGlow(.purple)
                    .disabled(engine.isUserPaused)
                }
            }

            if auth.sessionKey != nil {
                Button {
                    if let url = auth.freshProfileURL() {
                        openURL(url)
                    }
                } label: {
                    Label(NSLocalizedString("View Profile in Last.fm", comment: ""), systemImage: "person.circle")
                        .font(.body.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: actionButtonHeight)
                }
                .buttonStyle(.borderedProminent)
                .pillButtonBorder()
                .tint(.blue)
                .buttonGlow(.blue)
                .disabled(auth.profileURL == nil)

                Button {
                    isShowingManualScrobble = true
                } label: {
                    Label(NSLocalizedString("Manual Scrobble", comment: ""), systemImage: "plus.circle")
                        .font(.body.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: actionButtonHeight)
                }
                .buttonStyle(.bordered)
                .pillButtonBorder()
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var macAttentionBanner: some View {
        let isLoggedOut = (auth.sessionKey == nil)
        let isMediaLibraryPermissionOff = (permissions.mediaLibraryStatus != .authorized)
        let isMusicControlPermissionOff = (permissions.automationStatus != .authorized)
        if isLoggedOut || isMediaLibraryPermissionOff || isMusicControlPermissionOff {
            VStack(alignment: .leading, spacing: 10) {
                if isLoggedOut {
                    Label(
                        "You're signed out of Last.fm.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .font(.subheadline.weight(.semibold))
                }

                if isMusicControlPermissionOff {
                    Label(
                        "Music control permission is off. Enable it in System Settings → Privacy & Security → Automation.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                }

                if isMediaLibraryPermissionOff {
                    Label(
                        "Media Library permission is off. Request it here or enable it in System Settings → Privacy & Security.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                }

                HStack(spacing: 10) {
                    if isLoggedOut {
                        Button("Sign In") {
                            isShowingSettings = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }

                    if permissions.mediaLibraryStatus == .notDetermined {
                        Button("Request Media Library Access") {
                            Task { @MainActor in
                                let status: MPMediaLibraryAuthorizationStatus = await withCheckedContinuation { cont in
                                    MPMediaLibrary.requestAuthorization { s in
                                        cont.resume(returning: s)
                                    }
                                }
                                await permissions.refreshNow(observer: observer)
                                guard status == .authorized else { return }
                                AppModel.shared.startIfNeeded()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    } else if permissions.mediaLibraryStatus == .denied || permissions.mediaLibraryStatus == .restricted {
                        Button(NSLocalizedString("Open System Settings", comment: "")) {
                            if let mediaSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                                openURL(mediaSettingsURL)
                            } else if let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                                openURL(privacySettingsURL)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }

                    if isMusicControlPermissionOff {
                        Button(NSLocalizedString("Open System Settings", comment: "")) {
                            if let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                openURL(automationSettingsURL)
                            } else if let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                                openURL(privacySettingsURL)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }

                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
        }
    }

    private var scrobbleLogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Scrobbles")
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            if scrobbleLog.entries.isEmpty {
                Text("No scrobbles yet.")
                    .foregroundColor(.secondary)
            } else {
                let entries = scrobbleLog.recentEntries()
                VStack(spacing: 10) {
                    ForEach(entries) { entry in
                        ScrobbleLogRowView(
                            entry: entry,
                            isLast: entry.id == entries.last?.id,
                            currentDate: currentDate,
                            engine: engine
                        )
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

    private func connectTapped() async {
        errorText = nil
        do {
            try await auth.connect()
            engine.start()
        } catch {
            if error is CancellationError { return }
            errorText = error.localizedDescription
        }
    }

    private func handleTimerTick(now: Date) {
        secondTick &+= 1
        refreshScrobbleLogDisplay(now: now)
    }

    private func refreshScrobbleLogDisplay(now: Date, forceReload: Bool = false) {
        currentDate = now
        guard forceReload || now.timeIntervalSince(lastScrobbleLogRefreshDate) >= 60 else { return }
        scrobbleLog.reload()
        lastScrobbleLogRefreshDate = now
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func engineStatusText(_ status: String) -> Text {
        let parts = status
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var text = Text("Engine: ")
        for (idx, part) in parts.enumerated() {
            if idx > 0 { text = text + Text(" | ") }
            let segment = Text(part)
            if part == NSLocalizedString("error scrobbling", comment: "") {
                text = text + segment.fontWeight(.bold).foregroundColor(.red)
            } else if part == NSLocalizedString("now playing sent", comment: "") || part == NSLocalizedString("scrobbled", comment: "") {
                text = text + segment.fontWeight(.bold)
            } else {
                text = text + segment
            }
        }
        return text
    }

    private func presentSetupIfNeeded() {
        let shouldShow = (!hasSeenSetup || auth.sessionKey == nil || permissions.automationStatus != .authorized)
        guard shouldShow else { return }

        isShowingHelp = false
        if !isShowingSetup {
            isShowingSetup = true
        }
    }

    private func refreshPermissionStatusesIfNeeded() {
        Task { @MainActor in
            await permissions.refreshNow(observer: observer)
            observer.refreshOnceIfAuthorized()
            presentSetupIfNeeded()

            if hasSeenSetup, auth.sessionKey != nil, permissions.automationStatus == .authorized {
                AppModel.shared.startIfNeeded()
            }
        }
    }

    private func presentWhatsNewIfNeeded() {}

    private func dismissWhatsNew() {
        WhatsNewRelease.markSeen()
        isShowingWhatsNew = false
    }
}

private struct ScrobbleLogRowView: View {
    let entry: ScrobbleLogStore.Entry
    let isLast: Bool
    let currentDate: Date
    let engine: ScrobbleEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(entry.track.artist) — \(entry.track.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if entry.track.artist.isEmpty || entry.track.title.isEmpty {
                    Text("Error")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(Color.orange)
                        .clipShape(Capsule())
                }
            }
            if let album = entry.track.album, !album.isEmpty {
                Text(album)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 8) {
                Text(RelativeScrobbleTimeFormatter.string(from: entry.scrobbledAt, to: currentDate))
                if entry.lovedOnLastFM == true {
                    Text("Loved")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
                if entry.source != .live {
                    Text(sourceLabel(entry.source))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Suppress inherited animations so new scrobble rows appear instantly rather than sliding in.
        .transaction { $0.animation = nil }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                Task {
                    try? await engine.submitManualScrobble(
                        artist: entry.track.artist,
                        title: entry.track.title,
                        album: entry.track.album,
                        albumArtist: entry.track.albumArtist,
                        timestamp: Int(Date().timeIntervalSince1970)
                    )
                }
            } label: {
                Label("Scrobble Again", systemImage: "arrow.clockwise")
            }
        } preview: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(entry.track.artist) — \(entry.track.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if entry.track.artist.isEmpty || entry.track.title.isEmpty {
                        Text("Error")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(Color.orange)
                            .clipShape(Capsule())
                    }
                }
                if let album = entry.track.album, !album.isEmpty {
                    Text(album)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 8) {
                    Text(RelativeScrobbleTimeFormatter.string(from: entry.scrobbledAt, to: currentDate))
                    if entry.lovedOnLastFM == true {
                        Text("Loved")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                    if entry.source != .live {
                        Text(sourceLabel(entry.source))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.primary)
            }
            .padding()
        }

        if !isLast {
            Divider()
        }
    }

    private func sourceLabel(_ source: ScrobbleLogStore.Source) -> String {
        switch source {
        case .live: return ""
        case .backlog: return NSLocalizedString("Backlog", comment: "")
        case .playbackHistory: return NSLocalizedString("Listening History", comment: "")
        case .recentlyPlayed: return NSLocalizedString("Recently Played", comment: "")
        case .manual: return NSLocalizedString("Manual", comment: "")
        }
    }

}

extension View {
    @ViewBuilder
    func onValueChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (_ newValue: Value) -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            onChange(of: value, perform: action)
        }
    }
}

extension View {
    @ViewBuilder
    func pillButtonBorder() -> some View {
        if #available(macOS 14.0, *) {
            self.buttonBorderShape(.capsule)
        } else {
            self.buttonBorderShape(.roundedRectangle)
        }
    }

    func buttonGlow(_ color: Color) -> some View {
        self.shadow(color: color.opacity(0.30), radius: 6, x: 0, y: 0)
    }
}

enum MacFloatingBarLayout {
    static let contentTopPadding: CGFloat = 52
    static let circleButtonContentTopPadding: CGFloat = 28
}

struct MacCapsuleBar<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
    }
}

struct MacFloatingCircleButton: View {
    let systemImage: String
    let help: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

extension ContentView {
    @ViewBuilder
    var macModalOverlay: some View {
        let isPresented = (isShowingSetup || isShowingHelp || isShowingSettings || isShowingManualScrobble)
        if isPresented {
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        // Don't let a backdrop tap dismiss onboarding — the user must complete setup.
                        if !isShowingSetup {
                            dismissMacModal()
                        }
                    }

                macModalContent
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
                    .padding(12)
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: isPresented)
        }
    }

    @ViewBuilder
    var macModalContent: some View {
        if isShowingSetup {
            SetupHelpView(mode: .onboarding, onOpenSettings: {
                isShowingSetup = false
                isShowingSettings = true
            }) {
                hasSeenSetup = true
                isShowingSetup = false
                presentWhatsNewIfNeeded()
                Task { @MainActor in
                    AppModel.shared.startIfNeeded()
                }
            }
        } else if isShowingHelp {
            SetupHelpView(mode: .help, onOpenSettings: {
                isShowingHelp = false
                isShowingSettings = true
            }) {
                isShowingHelp = false
            }
        } else if isShowingSettings {
            SettingsView(onBack: { isShowingSettings = false })
        } else if isShowingManualScrobble {
            ManualScrobbleView(onBack: { isShowingManualScrobble = false })
        }
    }

    func dismissMacModal() {
        if isShowingSettings {
            isShowingSettings = false
        } else if isShowingHelp {
            isShowingHelp = false
        } else if isShowingManualScrobble {
            isShowingManualScrobble = false
        } else if isShowingSetup {
            // Keep onboarding visible until the setup requirements are actually satisfied.
            return
        }
    }
}
