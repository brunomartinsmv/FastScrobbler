import SwiftUI

struct AppleMusicAPISettingsPage: View {
    @AppStorage(AppSettings.Keys.scrobbleAppleMusicAPIEnabled, store: AppGroup.userDefaults) private var scrobbleAppleMusicAPIEnabled = false
    @AppStorage(AppSettings.Keys.scrobbleOnlyNonLibraryAppleMusicAPITracks, store: AppGroup.userDefaults) private var scrobbleOnlyNonLibraryAppleMusicAPITracks = true

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Toggle("Scrobble from Apple Music API", isOn: $scrobbleAppleMusicAPIEnabled)
                            .onValueChange(of: scrobbleAppleMusicAPIEnabled) { isEnabled in
                                Task {
                                    await AppModel.shared.handleAppleMusicAPIScrobblingChanged(isEnabled: isEnabled)
                                }
                            }
                    }
                    .padding(.bottom, 16)

                    Divider()

                    VStack(alignment: .leading, spacing: 0) {
                        Text(localized("Beta feature: Automatically scrobbles up to 30 recently played songs via the Apple Music API. Songs are recorded even when FastScrobbler is in the background.\n\nNote: playback timestamps aren’t provided by the API, so FastScrobbler assigns an estimated timestamp when the scrobble is submitted. Songs are recorded and scrobbled regardless of playback duration."))
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    .padding(.top, 16)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Toggle(localized("Only scrobble non-library songs"), isOn: $scrobbleOnlyNonLibraryAppleMusicAPITracks)
                            .disabled(!scrobbleAppleMusicAPIEnabled)
                            .foregroundStyle(scrobbleAppleMusicAPIEnabled ? .primary : .secondary)
                            .tint(.red)
                    }
                    .padding(.bottom, 16)

                    Divider()

                    VStack(alignment: .leading, spacing: 0) {
                        Text(localized("Best-effort filter: FastScrobbler checks for recently played API songs that are present in your library, and skips them. If FastScrobbler can't confirm a match, the song will be scrobbled. Recommended when \"Scrobble from Listening History\" is enabled."))
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    .padding(.top, 16)
                }
            }
        }
        .navigationTitle(localized("Scrobble from Apple Music API"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
