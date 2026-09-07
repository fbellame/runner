import UIKit

/// `UIFeedbackGenerator` and its subclasses are main-actor-isolated, so under
/// `SWIFT_STRICT_CONCURRENCY: complete` a nonisolated `static func` calling them
/// is a warning today and an error under a future language mode. Both call sites
/// are already on the main actor (a SwiftUI view body and `WorkoutRecorder`'s
/// km-split callback), so isolating the enum costs nothing.
@MainActor
enum Haptics {
    static func goalReached() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func kmSplit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
