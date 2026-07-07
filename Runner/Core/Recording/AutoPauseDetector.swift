import Foundation

struct AutoPauseDetector {
    let pauseSpeedThreshold: Double
    let pauseAfter: TimeInterval
    let resumeAfter: TimeInterval = 3

    private(set) var isPaused = false
    private var belowSince: Date?
    private var aboveSince: Date?

    init(activity: ActivityType) {
        switch activity {
        case .run, .walk:
            pauseSpeedThreshold = 0.5
            pauseAfter = 10
        case .bike:
            pauseSpeedThreshold = 1.0
            pauseAfter = 15
        }
    }

    mutating func update(speed: Double, at time: Date) -> Bool {
        if isPaused {
            if speed > pauseSpeedThreshold {
                if aboveSince == nil { aboveSince = time }
                if time.timeIntervalSince(aboveSince!) >= resumeAfter {
                    isPaused = false
                    belowSince = nil
                    aboveSince = nil
                }
            } else {
                aboveSince = nil
            }
        } else {
            if speed < pauseSpeedThreshold {
                if belowSince == nil { belowSince = time }
                if time.timeIntervalSince(belowSince!) >= pauseAfter {
                    isPaused = true
                    aboveSince = nil
                }
            } else {
                belowSince = nil
            }
        }
        return isPaused
    }
}
