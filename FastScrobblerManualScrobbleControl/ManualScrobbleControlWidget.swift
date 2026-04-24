import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
@main
struct ManualScrobbleControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kevin.FastScrobbler.control.manualScrobble") {
            ControlWidgetButton(action: OpenManualScrobbleIntent()) {
                Label("Manual Scrobble", systemImage: "plus.circle")
            }
            .tint(.orange)
        }
        .displayName("Manual Scrobble")
        .description("Open the Manual Scrobble screen in FastScrobbler.")
    }
}
