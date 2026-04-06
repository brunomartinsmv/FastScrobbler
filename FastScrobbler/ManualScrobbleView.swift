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

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
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
        scrobbleLog.entries
            .filter { $0.source == .manual }
            .prefix(30)
            .map { $0 }
    }

    var body: some View {
#if os(iOS)
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
            .onChange(of: artist) { _, v in if v.count > 500 { artist = String(v.prefix(500)) } }
            .onChange(of: title) { _, v in if v.count > 500 { title = String(v.prefix(500)) } }
            .onChange(of: album) { _, v in if v.count > 500 { album = String(v.prefix(500)) } }
            .onChange(of: albumArtist) { _, v in if v.count > 500 { albumArtist = String(v.prefix(500)) } }
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
#else
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(localized("Manual Scrobble"))
                    .font(.title.bold())
                    .padding(.top, MacFloatingBarLayout.contentTopPadding)

                macField(localized("Artist"), text: $artist)
                macField(localized("Song title"), text: $title)
                macField(localized("Album"), text: $album)
                macField(localized("Album artist"), text: $albumArtist)

                    Divider()

                    VStack(alignment: .leading, spacing: 0) {
                    Text(localized("Timestamp"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Picker(localized("Timestamp"), selection: $useCustomTimestamp) {
                        Text(localized("Now")).tag(false)
                        Text(localized("Custom…")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .font(.headline)
                    .frame(height: 64)

                    if useCustomTimestamp {
                        DatePicker(
                            localized("Date & Time"),
                            selection: $customDate,
                            in: Self.twoWeeksAgo...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        Text(localized("Last.fm will reject scrobbles older than two weeks."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                    }

                    if let errorText {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            Spacer()
                            if isSubmitting {
                                ProgressView().controlSize(.small).tint(.white)
                            } else if isSubmitted {
                                Image(systemName: "checkmark.circle.fill")
                                Text(localized("Submitted"))
                            } else {
                                Text(localized("Submit Scrobble"))
                            }
                            Spacer()
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                        .animation(.easeOut(duration: 0.25), value: isSubmitted)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isSubmitted ? .green : .accentColor)
                    .disabled(!canSubmit)
                    .frame(maxWidth: .infinity)

                    if !manualLogEntries.isEmpty {
                        Divider()

                        Text(localized("Manual Scrobble Log"))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(manualLogEntries) { entry in
                                logEntryRow(entry, now: now)
                                if entry.id != manualLogEntries.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.thinMaterial)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
                    }
                }
                .padding()
        }
        .onChange(of: artist) { _, v in if v.count > 500 { artist = String(v.prefix(500)) } }
        .onChange(of: title) { _, v in if v.count > 500 { title = String(v.prefix(500)) } }
        .onChange(of: album) { _, v in if v.count > 500 { album = String(v.prefix(500)) } }
        .onChange(of: albumArtist) { _, v in if v.count > 500 { albumArtist = String(v.prefix(500)) } }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            MacFloatingCircleButton(
                systemImage: "chevron.left",
                help: localized("Back"),
                accessibilityLabel: localized("Back"),
                action: { if let onBack { onBack() } else { dismiss() } }
            )
            .padding(.top, 10)
            .padding(.leading, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
#endif
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
                Text(relativeHoursMinutes(from: entry.scrobbledAt, to: now))
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
        case .recentlyPlayed: return NSLocalizedString("Recently Played", comment: "")
        case .manual: return NSLocalizedString("Manual", comment: "")
        }
    }

    private func relativeHoursMinutes(from date: Date, to now: Date) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        let totalMinutes = Int(delta / 60)
        if totalMinutes < 60 {
            return String.localizedStringWithFormat(NSLocalizedString("%lldm ago", comment: ""), Int64(totalMinutes))
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return String.localizedStringWithFormat(NSLocalizedString("%lldh ago", comment: ""), Int64(hours))
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("%1$lldh %2$lldm ago", comment: ""),
            Int64(hours),
            Int64(minutes)
        )
    }

#if os(macOS)
    private func macField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
#endif

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
