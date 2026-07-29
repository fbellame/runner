import Foundation

struct AutoPauseDetector {
    let pauseSpeedThreshold: Double
    let pauseAfter: TimeInterval
    let resumeAfter: TimeInterval
    let instantResumeSpeed: Double
    let maxPlausibleSpeed: Double

    private(set) var isPaused: Bool
    private var belowSince: Date?
    private var aboveSince: Date?

    init(activity: ActivityType, startPaused: Bool = false) {
        self.isPaused = startPaused
        switch activity {
        case .run, .walk:
            pauseSpeedThreshold = 0.5
            pauseAfter = 6
            resumeAfter = 1
            instantResumeSpeed = 1.5
            maxPlausibleSpeed = 8.0
        case .bike:
            pauseSpeedThreshold = 1.0
            pauseAfter = 10
            resumeAfter = 1
            instantResumeSpeed = 3.0
            maxPlausibleSpeed = 25.0
        }
    }

    mutating func update(speed: Double, at time: Date) -> Bool {
        if isPaused {
            if speed >= instantResumeSpeed, speed <= maxPlausibleSpeed {
                isPaused = false
                belowSince = nil
                aboveSince = nil
            } else if speed > pauseSpeedThreshold {
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
