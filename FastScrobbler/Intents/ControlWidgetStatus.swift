import Foundation
import WidgetKit

enum ControlWidgetStatusPhase: String, Codable, Sendable {
    case idle
    case inProgress
    case success
}

enum ControlWidgetStatusKind: String, Sendable {
    case sendNowPlaying = "com.kevin.FastScrobbler.control.sendNowPlaying"
    case scrobbleSong = "com.kevin.FastScrobbler.control.scrobbleSong"
    case scanListeningHistory = "com.kevin.FastScrobbler.control.scanListeningHistory"
}

private struct ControlWidgetStatusEntry: Codable {
    var phase: ControlWidgetStatusPhase
    var expiresAt: Date?
}

enum ControlWidgetStatusStore {
    private static let storageKey = "FastScrobbler.ControlWidgetStatus.entries"
    static let successDisplayDuration: TimeInterval = 2

    static func currentPhase(for kind: ControlWidgetStatusKind, now: Date = Date()) -> ControlWidgetStatusPhase {
        var entries = loadEntries()
        guard let entry = entries[kind.rawValue] else { return .idle }

        if let expiresAt = entry.expiresAt, expiresAt <= now {
            entries.removeValue(forKey: kind.rawValue)
            saveEntries(entries)
            return .idle
        }

        return entry.phase
    }

    static func markInProgress(_ kind: ControlWidgetStatusKind) {
        update(kind: kind, entry: ControlWidgetStatusEntry(phase: .inProgress, expiresAt: nil))
        reload(kind)
    }

    static func markSuccess(_ kind: ControlWidgetStatusKind, duration: TimeInterval = successDisplayDuration) {
        let expiresAt = Date().addingTimeInterval(max(0, duration))
        update(kind: kind, entry: ControlWidgetStatusEntry(phase: .success, expiresAt: expiresAt))
        reload(kind)
        scheduleExpiryReload(for: kind, at: expiresAt)
    }

    static func clear(_ kind: ControlWidgetStatusKind) {
        var entries = loadEntries()
        entries.removeValue(forKey: kind.rawValue)
        saveEntries(entries)
        reload(kind)
    }

    private static func update(kind: ControlWidgetStatusKind, entry: ControlWidgetStatusEntry) {
        var entries = loadEntries()
        entries[kind.rawValue] = entry
        saveEntries(entries)
    }

    private static func scheduleExpiryReload(for kind: ControlWidgetStatusKind, at expiresAt: Date) {
        Task.detached {
            let interval = expiresAt.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            await MainActor.run {
                if #available(iOS 18.0, *) {
                    ControlCenter.shared.reloadControls(ofKind: kind.rawValue)
                }
            }
        }
    }

    private static func reload(_ kind: ControlWidgetStatusKind) {
        Task { @MainActor in
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: kind.rawValue)
            }
        }
    }

    private static func loadEntries() -> [String: ControlWidgetStatusEntry] {
        guard let data = AppGroup.userDefaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ControlWidgetStatusEntry].self, from: data)) ?? [:]
    }

    private static func saveEntries(_ entries: [String: ControlWidgetStatusEntry]) {
        if entries.isEmpty {
            AppGroup.userDefaults.removeObject(forKey: storageKey)
            return
        }

        if let data = try? JSONEncoder().encode(entries) {
            AppGroup.userDefaults.set(data, forKey: storageKey)
        }
    }
}

struct ControlWidgetStatusProvider: ControlValueProvider {
    let kind: ControlWidgetStatusKind

    var previewValue: ControlWidgetStatusPhase { .idle }

    func currentValue() async throws -> ControlWidgetStatusPhase {
        ControlWidgetStatusStore.currentPhase(for: kind)
    }
}
