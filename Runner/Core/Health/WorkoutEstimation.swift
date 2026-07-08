import Foundation

enum WorkoutEstimation {
    // ~15 km/h average city cycling.
    static let cyclingMetersPerSecond = 15_000.0 / 3600.0

    static func estimatedMeters(type: ActivityType, movingSeconds: Double) -> Double? {
        guard movingSeconds > 0 else { return nil }
        switch type {
        case .bike:
            return movingSeconds * cyclingMetersPerSecond
        case .run, .walk:
            return nil
        }
    }
}
