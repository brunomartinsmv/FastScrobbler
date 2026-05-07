import SwiftUI

struct WhatsNewView: View {
    struct VersionSection: Identifiable {
        let id: String
        let version: String
        let features: [Feature]
    }

    struct Feature: Identifiable {
        var id: String { title }
        let systemImage: String
        let title: String
        let showsProBadge: Bool
    }

    private let currentSections: [VersionSection] = [
        VersionSection(
            id: "5.4",
            version: "5.4",
            features: [
                Feature(
                    systemImage: "square.and.arrow.down.badge.clock",
                    title: "\"Scrobble from Apple Music API\" feature",
                    showsProBadge: false
                ),
                Feature(
                    systemImage: "person.crop.rectangle",
                    title: "\"Scrobble only the first credited artist\" feature",
                    showsProBadge: true
                )
            ]
        )
    ]

    private let previousSections: [VersionSection] = [
        VersionSection(
            id: "4.0",
            version: "4.0",
            features: [
                Feature(
                    systemImage: "textformat.abc",
                    title: "Text replacement feature: Find and replace keywords when scrobbling",
                    showsProBadge: true
                ),
                Feature(
                    systemImage: "plus.circle",
                    title: "Manual scrobbling feature",
                    showsProBadge: false
                ),
                Feature(
                    systemImage: "hand.tap",
                    title: "Tap and hold on a scrobbled song to scrobble it again",
                    showsProBadge: false
                )
            ]
        ),
        VersionSection(
            id: "3.3",
            version: "3.3",
            features: [
                Feature(
                    systemImage: "person.2.wave.2",
                    title: "Added links to the r/FastScrobbler subreddit in the Settings page.\n\nFor any questions or bug reports, submit a post to r/FastScrobbler and FastScrobbler will respond to you.",
                    showsProBadge: false
                )
            ]
        ),
        VersionSection(
            id: "3.2",
            version: "3.2",
            features: [
                Feature(
                    systemImage: "parentheses",
                    title: "\"Remove brackets in album titles\" feature",
                    showsProBadge: true
                )
            ]
        ),
        VersionSection(
            id: "3.0",
            version: "3.0",
            features: [
                Feature(
                    systemImage: "parentheses",
                    title: "\"Remove brackets in song titles\" feature",
                    showsProBadge: true
                ),
                Feature(
                    systemImage: "clock.arrow.circlepath",
                    title: "Toggle to disable the \"Scrobble from Listening History\" functionality",
                    showsProBadge: false
                )
            ]
        ),
        VersionSection(
            id: "2.0",
            version: "2.0",
            features: [
                Feature(
                    systemImage: "globe",
                    title: "Support for Chinese (Simplified), French, Japanese, and Spanish",
                    showsProBadge: false
                ),
                Feature(
                    systemImage: "person.2",
                    title: "Album artist scrobbling support",
                    showsProBadge: false
                )
            ]
        )
    ]

    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header

                    VersionSectionList(sections: currentSections)

                    NavigationLink {
                        WhatsNewPreviousVersionsView(sections: previousSections)
                    } label: {
                        Text(NSLocalizedString("View Previous Versions", comment: ""))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)

                    Button(action: onContinue) {
                        Text(NSLocalizedString("Done", comment: ""))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .cancel) {
                        onContinue()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Text(NSLocalizedString("What's New", comment: ""))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    struct VersionSectionList: View {
        let sections: [VersionSection]

        var body: some View {
            VStack(spacing: 18) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Version \(section.version)")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 12) {
                            ForEach(section.features) { feature in
                                WhatsNewFeatureCard(
                                    systemImage: feature.systemImage,
                                    title: feature.title,
                                    showsProBadge: feature.showsProBadge
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct WhatsNewPreviousVersionsView: View {
    let sections: [WhatsNewView.VersionSection]

    var body: some View {
        ScrollView {
            WhatsNewView.VersionSectionList(sections: sections)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("Previous Versions", comment: ""))
    }
}

private struct WhatsNewFeatureCard: View {
    let systemImage: String
    let title: String
    let showsProBadge: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title)
                .font(.body)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsProBadge {
                Text("Pro")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
