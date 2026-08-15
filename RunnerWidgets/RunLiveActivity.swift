import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunAttributes.self) { context in
            let snapshot = context.state.snapshot
            VStack(alignment: .leading, spacing: 10) {
                Text(title(for: snapshot))
                    .font(.headline)
                    .invalidatableContent()
                // `.error`'s headline already IS `snapshot.message` (see
                // `title(for:)` below) — showing it again as the caption
                // would render the same sentence twice. Every other status's
                // headline is a fixed phrase, so its optional `message`
                // (e.g. the reduced-accuracy warning) is genuinely new
                // information and still belongs in the caption.
                if let message = snapshot.message, snapshot.status != .error {
                    Text(message).font(.caption)
                }
                HStack {
                    stat(String(localized: "Time"), WidgetFormat.duration(snapshot.movingSeconds))
                    stat(String(localized: "Distance"), WidgetFormat.km(snapshot.distanceMeters))
                    stat(String(localized: "Pace"), WidgetFormat.pace(snapshot.paceSecondsPerKm))
                }
                .invalidatableContent()
                if snapshot.status != .ready && snapshot.status != .finished {
                    HStack {
                        Button(intent: TogglePauseIntent()) {
                            Label(
                                snapshot.status == .paused
                                    ? String(localized: "Resume")
                                    : String(localized: "Pause"),
                                systemImage: snapshot.status == .paused
                                    ? "play.fill"
                                    : "pause.fill"
                            )
                        }
                        .invalidatableContent()
                        Button(intent: FinishRunIntent()) {
                            Label(String(localized: "Finish"),
                                  systemImage: "stop.fill")
                        }
                        .invalidatableContent()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(Color.green)
        } dynamicIsland: { context in
            let snapshot = context.state.snapshot
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(WidgetFormat.duration(snapshot.movingSeconds))
                        .invalidatableContent()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(WidgetFormat.km(snapshot.distanceMeters))
                        .invalidatableContent()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(title(for: snapshot))
                        .invalidatableContent()
                }
            } compactLeading: {
                Image(systemName: snapshot.status == .paused
                      ? "pause.fill" : "figure.run")
            } compactTrailing: {
                Text(WidgetFormat.duration(snapshot.movingSeconds))
            } minimal: {
                Image(systemName: "figure.run")
            }
        }
    }

    private func title(for snapshot: RunActivitySnapshot) -> String {
        switch snapshot.status {
        case .ready: String(localized: "Ready — start moving")
        case .recording: String(localized: "Run in progress")
        case .paused: String(localized: "Paused")
        case .finished: String(localized: "Run finished")
        case .error: snapshot.message ?? String(localized: "Location access is required")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption2)
            Text(value).font(.caption.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum WidgetFormat {
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d",
                      total / 3600, (total % 3600) / 60, total % 60)
    }

    static func km(_ meters: Double) -> String {
        String(format: "%.2f km", meters / 1000)
    }

    static func pace(_ secondsPerKm: Double?) -> String {
        guard let secondsPerKm else { return "—" }
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d /km", total / 60, total % 60)
    }
}
