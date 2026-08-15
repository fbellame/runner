import AppIntents
import SwiftUI
import WidgetKit

/// iOS 18 Control Center / Lock Screen control that arms a run without
/// unlocking the phone. Backed by `StartRunIntent` (`LiveActivityIntent`),
/// which runs in the app process and may background-launch Runner.
struct StartRunControl: ControlWidget {
    static let kind = "com.farid.runner.start-run"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartRunIntent()) {
                Label(String(localized: "Start Run"),
                      systemImage: "figure.run")
            }
        }
        .displayName("Start Run")
        .description("Arm a run without unlocking Runner.")
    }
}
