import SwiftUI

struct AppleMusicAPISettingsPage: View {
    @AppStorage(AppSettings.Keys.scrobbleAppleMusicAPIEnabled, store: AppGroup.userDefaults) private var scrobbleAppleMusicAPIEnabled = false
    @AppStorage(AppSettings.Keys.scrobbleOnlyNonLibraryAppleMusicAPITracks, store: AppGroup.userDefaults) private var scrobbleOnlyNonLibraryAppleMusicAPITracks = false

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
                        Text("Experimental feature: Automatically scrobbles up to 30 recently played songs via the Apple Music API. Songs are recorded even while FastScrobbler is in the background.\n\nNote: playback timestamps aren’t provided by Apple here, so FastScrobbler assigns an estimated timestamp when it submits the scrobble. Songs are recorded and scrobbled regardless of playback duration.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                        Text(localized("Best-effort filter: FastScrobbler compares recent Apple Music API tracks against your local library and skips songs that appear to already be in it. If a match can't be confirmed, the song is still scrobbled."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 16)
                }
            }
        }
        .navigationTitle(localized("Scrobble from Apple Music API"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
