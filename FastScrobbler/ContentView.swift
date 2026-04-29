import MediaPlayer
import SwiftUI
#if canImport(SafariServices) && canImport(UIKit)
import SafariServices
#endif
#if canImport(WebKit)
import WebKit
#endif

struct ContentView: View {
    private enum Keys {
        static let hasSeenSetup = "FastScrobbler.Setup.hasSeen"
    }

    @EnvironmentObject private var auth: LastFMAuthManager
    @EnvironmentObject private var observer: AppleMusicNowPlayingObserver
    @EnvironmentObject private var engine: ScrobbleEngine
    @EnvironmentObject private var scrobbleLog: ScrobbleLogStore
    @EnvironmentObject private var pro: ProPurchaseManager

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(Keys.hasSeenSetup) private var hasSeenSetup = false

    @State private var currentDate: Date = .now
    // Incrementing secondTick every second forces SwiftUI to re-evaluate computed views
    // (statusCard, trackCard) that display live elapsed time without a dedicated @Published property.
    @State private var secondTick: Int = 0
    @State private var errorText: String?
    @State private var isShowingSetup = false
    @State private var isShowingWhatsNew = false
    @State private var isShowingHelp = false
    @State private var isShowingSettings = false
    @State private var isShowingManualScrobble = false

    @State private var inAppBrowserURL: URL?
    @State private var prevBounce = 0
    @State private var nextBounce = 0

    private enum Tab { case home, settings }
    @State private var selectedTab: Tab = .home


    var body: some View {
        Group {
            // TabView keeps both tabs alive so the engine continues running in the background.
            TabView(selection: $selectedTab) {
                NavigationView {
                    mainContent
                }
                .tabItem { Label("Home", systemImage: UIImage(systemName: "music.note.arrow.trianglehead.clockwise") != nil ? "music.note.arrow.trianglehead.clockwise" : "music.note") }
                .tag(Tab.home)

                settingsTabContent
                    .tabItem { Label("Settings", systemImage: "gear") }
                    .tag(Tab.settings)
            }

        }
        .onAppear {
            refreshMediaLibraryStatusIfNeeded()
            presentSetupIfNeeded()
            presentWhatsNewIfNeeded()
        }
        .onValueChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            refreshMediaLibraryStatusIfNeeded()
            presentSetupIfNeeded()
            presentWhatsNewIfNeeded()
            if hasSeenSetup {
                AppModel.shared.startIfNeeded()
            }
        }
        .onValueChange(of: observer.authorizationStatus) { _ in
            refreshMediaLibraryStatusIfNeeded()
            presentSetupIfNeeded()
        }
        .onValueChange(of: hasSeenSetup) { hasSeenSetup in
            guard hasSeenSetup else { return }
            presentWhatsNewIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openManualScrobble)) { _ in
            isShowingManualScrobble = true
        }
        .fullScreenCover(isPresented: $isShowingSetup) {
            SetupHelpView(mode: .onboarding) {
                guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
                guard auth.sessionKey != nil else { return }
                hasSeenSetup = true
                isShowingSetup = false
                presentWhatsNewIfNeeded()
                AppModel.shared.startIfNeeded()
            }
        }
        .fullScreenCover(isPresented: $isShowingWhatsNew) {
            WhatsNewView {
                dismissWhatsNew()
            }
        }
        .fullScreenCover(isPresented: $isShowingHelp) {
            SetupHelpView(mode: .help, hideTitle: true) {
                isShowingHelp = false
            }
        }
        // Custom Binding because .sheet(item:) would require URL: Identifiable.
        .sheet(isPresented: Binding(
            get: { inAppBrowserURL != nil },
            set: { isPresented in
                if !isPresented {
                    inAppBrowserURL = nil
                }
            }
        )) {
            if let url = inAppBrowserURL {
                InAppSafariView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.3), value: observer.track)
            .animation(.easeInOut(duration: 0.3), value: auth.sessionKey != nil)
            .animation(.easeInOut(duration: 0.3), value: engine.statusText)
        }
        .refreshable {
            await refreshHome()
        }
        .overlay(alignment: .top) {
            GeometryReader { geo in
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        Color(.systemBackground).opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // SE has a ~20pt status bar; notch/Dynamic Island devices have ~50pt+.
                // Use the safe area top inset to scale the gradient height accordingly.
                .frame(height: geo.safeAreaInsets.top < 30 ? 50 : 70)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .ignoresSafeArea(edges: .top)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            secondTick &+= 1 // &+= wraps on overflow instead of crashing after ~68 years of uptime
        }
        .navigationTitle("")
    }

    private var settingsTabContent: some View {
        SettingsView(isShowingHelp: $isShowingHelp)
            .environment(\.isEmbeddedInTab, true)
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
                        HStack(spacing: 32) {
                            Button {
                                prevBounce += 1
                                observer.skipToPreviousItem()
                            } label: {
                                Image(systemName: "backward.fill")
                                    .symbolEffect(.bounce, value: prevBounce)
                            }
                            .font(.title3)
                            Button { observer.togglePlayPause() } label: {
                                Image(systemName: observer.playbackState == .playing ? "pause.fill" : "play.fill")
                                    .contentTransition(.symbolEffect(.replace.downUp))
                                    .scaleEffect(observer.playbackState == .playing ? 1.0 : 1.15)
                                    .animation(.spring(response: 0.25, dampingFraction: 0.45), value: observer.playbackState)
                                    .frame(width: 32, height: 32)
                            }
                            .font(.title)
                            Button {
                                nextBounce += 1
                                observer.skipToNextItem()
                            } label: {
                                Image(systemName: "forward.fill")
                                    .symbolEffect(.bounce, value: nextBounce)
                            }
                            .font(.title3)
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: observer.playbackState)
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
        let actionButtonHeight: CGFloat = 40
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
                        inAppBrowserURL = url
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
        .sheet(isPresented: $isShowingManualScrobble) {
            ManualScrobbleView()
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
                let entries = Array(scrobbleLog.entries.prefix(30))
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
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            currentDate = date
        }
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

    @MainActor
    private func refreshHome() async {
        await AppModel.shared.scanListeningHistory()
        scrobbleLog.reload()
        currentDate = .now
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
        // Re-check on every scene activation — permissions can change while the app is backgrounded.
        let mediaAuthorized = (MPMediaLibrary.authorizationStatus() == .authorized)
        let shouldShow = (!hasSeenSetup || !mediaAuthorized || auth.sessionKey == nil)
        guard shouldShow else { return }

        isShowingHelp = false
        if !isShowingSetup {
            isShowingSetup = true
        }
    }

    private func refreshMediaLibraryStatusIfNeeded() {}

    private func presentWhatsNewIfNeeded() {
        guard hasSeenSetup else { return }
        guard !isShowingSetup && !isShowingWhatsNew && !isShowingHelp else { return }
        guard inAppBrowserURL == nil else { return }
        if WhatsNewRelease.shouldPresent() {
            isShowingWhatsNew = true
        }
    }

    private func dismissWhatsNew() {
        WhatsNewRelease.markSeen()
        isShowingWhatsNew = false
    }
}


private struct IsEmbeddedInTabKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isEmbeddedInTab: Bool {
        get { self[IsEmbeddedInTabKey.self] }
        set { self[IsEmbeddedInTabKey.self] = newValue }
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
                Text(RelativeScrobbleTimeFormatter.string(from: displayDate(for: entry), to: currentDate))
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
        // Suppress inherited list animations so new scrobble rows appear instantly rather than sliding in.
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
                    Text(RelativeScrobbleTimeFormatter.string(from: displayDate(for: entry), to: currentDate))
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

    private func displayDate(for entry: ScrobbleLogStore.Entry) -> Date {
        if entry.source == .playbackHistory {
            return Date(timeIntervalSince1970: TimeInterval(entry.startTimestamp))
        }
        return entry.scrobbledAt
    }

}

#if os(iOS)
private struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#elseif os(macOS)
private struct InAppSafariView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard nsView.url != url else { return }
        nsView.load(URLRequest(url: url))
    }
}
#endif

extension View {
    @ViewBuilder
    func onValueChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (_ newValue: Value) -> Void
    ) -> some View {
        onChange(of: value) { _, newValue in
            action(newValue)
        }
    }
}

struct IOSCloseButtonLabel: View {
    enum Style {
        case plain
        case floating
    }

    let style: Style

    init(style: Style = .floating) {
        self.style = style
    }

    var body: some View {
        let icon = Image(systemName: "xmark")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)

        switch style {
        case .plain:
            icon
        case .floating:
            icon
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
                .contentShape(Circle())
        }
    }
}

extension View {
    @ViewBuilder
    func pillButtonBorder() -> some View {
        self.buttonBorderShape(.capsule)
    }

    func buttonGlow(_ color: Color) -> some View {
        self.shadow(color: color.opacity(0.25), radius: 8, x: 0, y: 4)
            .shadow(color: color.opacity(0.40), radius: 7, x: 0, y: 4)
    }
}
