import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
@main
struct ScanListeningHistoryControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: ControlWidgetStatusKind.scanListeningHistory.rawValue,
            provider: ControlWidgetStatusProvider(kind: .scanListeningHistory)
        ) { phase in
            ControlWidgetButton(action: ScanListeningHistoryIntent()) {
                Label(title(for: phase), systemImage: "clock.arrow.circlepath")
            }
            .tint(.blue)
        }
        .displayName("Scan History")
        .description("Scan Listening History for missed scrobbles.")
    }

    private func title(for phase: ControlWidgetStatusPhase) -> LocalizedStringResource {
        switch phase {
        case .idle:
            return "Scan History"
        case .inProgress:
            return "Scrobbling..."
        case .success:
            return "Scrobbled"
        }
    }
}
