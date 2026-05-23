import SwiftUI

struct ManualScrobbleView: View {
    var onBack: (() -> Void)? = nil

    @EnvironmentObject private var engine: ScrobbleEngine
    @EnvironmentObject private var scrobbleLog: ScrobbleLogStore
    @Environment(\.dismiss) private var dismiss

    @State private var artist = ""
    @State private var title = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var useCustomTimestamp = false
    @State private var customDate = Date()
    @State private var isSubmitting = false
    @State private var isSubmitted = false
    @State private var errorText: String?
    @State private var now = Date()

    private static let twoWeeksAgo: Date = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()

    private func truncated(_ text: String) -> String {
        if text.count > 500 {
            return String(text.prefix(500))
        }
        return text
    }

    private var canSubmit: Bool {
        !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSubmitting &&
        !isSubmitted
    }

    private var timestamp: Int {
        let date = useCustomTimestamp ? customDate : Date()
        return Int(date.timeIntervalSince1970)
    }

    private var manualLogEntries: [ScrobbleLogStore.Entry] {
        scrobbleLog.manualEntries()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Artist").font(.footnote).foregroundStyle(.secondary)
                        TextField("Artist", text: $artist)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Song title").font(.footnote).foregroundStyle(.secondary)
                        TextField("Song title", text: $title)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Album").font(.footnote).foregroundStyle(.secondary)
                        TextField("Album", text: $album)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Album artist").font(.footnote).foregroundStyle(.secondary)
                        TextField("Album artist", text: $albumArtist)
                    }
                }

                Section("Timestamp") {
                    Picker("Timestamp", selection: $useCustomTimestamp) {
                        Text("Now").tag(false)
                        Text("Custom…").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .font(.headline)
                    .frame(height: 44)

                    if useCustomTimestamp {
                        DatePicker(
                            "Date & Time",
                            selection: $customDate,
                            in: Self.twoWeeksAgo...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        Text("Last.fm will reject scrobbles older than two weeks.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack(spacing: 8) {
                            Spacer()
                            if isSubmitting {
                                ProgressView().controlSize(.small).tint(.white)
                            } else if isSubmitted {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Submitted")
                            } else {
                                Text("Submit Scrobble")
                            }
                            Spacer()
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .animation(.easeOut(duration: 0.25), value: isSubmitted)
                    }
                    .listRowBackground(isSubmitted ? Color.green : Color.accentColor)
                    .opacity(canSubmit ? 1 : 0.4)
                    .disabled(!canSubmit)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if !manualLogEntries.isEmpty {
                    Section("Manual Scrobble Log") {
                        ForEach(manualLogEntries) { entry in
                            logEntryRow(entry, now: now)
                        }
                    }
                }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
                now = date
            }
            .onValueChange(of: artist) { artist = truncated($0) }
            .onValueChange(of: title) { title = truncated($0) }
            .onValueChange(of: album) { album = truncated($0) }
            .onValueChange(of: albumArtist) { albumArtist = truncated($0) }
            .navigationTitle("Manual Scrobble")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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

    @ViewBuilder
    private func logEntryRow(_ entry: ScrobbleLogStore.Entry, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(entry.track.artist) — \(entry.track.title)")
                .font(.subheadline.weight(.semibold))
            if let album = entry.track.album, !album.isEmpty {
                Text(album)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Text(RelativeScrobbleTimeFormatter.string(from: displayDate(for: entry), to: now))
                if entry.lovedOnLastFM == true {
                    Text("Loved")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .foregroundColor(.white)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
                if entry.source != .live && entry.source != .manual {
                    Text(sourceLabel(entry.source))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceLabel(_ source: ScrobbleLogStore.Source) -> String {
        switch source {
        case .live: return ""
        case .backlog: return NSLocalizedString("Backlog", comment: "")
        case .playbackHistory: return NSLocalizedString("Listening History", comment: "")
        case .recentlyPlayed: return NSLocalizedString("Recently Played API", comment: "")
        case .manual: return NSLocalizedString("Manual", comment: "")
        }
    }

    private func displayDate(for entry: ScrobbleLogStore.Entry) -> Date {
        if entry.source == .playbackHistory || entry.source == .recentlyPlayed {
            return Date(timeIntervalSince1970: TimeInterval(entry.startTimestamp))
        }
        return entry.scrobbledAt
    }

    private func submit() {
        errorText = nil
        isSubmitting = true
        let ts = timestamp
        Task {
            do {
                try await engine.submitManualScrobble(
                    artist: artist,
                    title: title,
                    album: album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : album,
                    albumArtist: albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : albumArtist,
                    timestamp: ts
                )
                isSubmitting = false
                withAnimation(.easeOut(duration: 0.25)) {
                    isSubmitted = true
                }
                try? await Task.sleep(for: .seconds(1))
                withAnimation(.easeOut(duration: 0.4)) {
                    isSubmitted = false
                }
            } catch {
                isSubmitting = false
                errorText = error.localizedDescription
            }
        }
    }
}
