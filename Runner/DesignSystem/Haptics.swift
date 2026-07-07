import UIKit

enum Haptics {
    static func goalReached() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func kmSplit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
