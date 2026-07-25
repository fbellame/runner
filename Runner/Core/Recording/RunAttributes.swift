import Foundation

/// Identifies which phase of a run a Live Activity should present. Pure,
/// ActivityKit-free by design — see `LiveActivityPresenting.swift` for why.
enum RunActivityStatus: String, Codable, Hashable, Sendable {
    case ready
    case recording
    case paused
    case finished
    case error
}

/// A point-in-time snapshot of a run, suitable for driving a Live Activity's
/// content state. Kept `Sendable` because it eventually crosses into a widget
/// extension process (Task 9).
struct RunActivitySnapshot: Codable, Hashable, Sendable {
    let status: RunActivityStatus
    let startedAt: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let paceSecondsPerKm: Double?
    let reducedAccuracy: Bool
    let message: String?
}

/// Identifies one Live Activity across its lifecycle. Deliberately does not
/// conform to `ActivityAttributes` here — that conformance (and the
/// `import ActivityKit` it requires) is added in Task 8, once the presenter
/// that actually talks to ActivityKit exists.
struct RunAttributes: Sendable {
    let sessionID: UUID
}

/// Target-neutral identifiers shared between the app and the `RunnerWidgets`
/// extension. Kept ActivityKit-free like the rest of this file.
enum RunnerWidgetContract {
    static let bundleIdentifier = "com.farid.runner.widgets"
    static let extensionPointIdentifier = "com.apple.widgetkit-extension"
}
