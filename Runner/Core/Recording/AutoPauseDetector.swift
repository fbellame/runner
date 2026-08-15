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
        // A speed no unassisted human can hold is a GPS re-acquisition glitch
        // (a reflection off a passing vehicle, a cold fix snapping into place),
        // not movement. Treat it as no information at all rather than as
        // "above threshold": gating only the instant-resume branch on the
        // ceiling still let two glitched samples a second apart satisfy the
        // ordinary dwell and un-pause a run standing at a red light. It must
        // likewise not reset the pause accumulator of a recording session.
        guard speed <= maxPlausibleSpeed else { return isPaused }
        if isPaused {
            if speed >= instantResumeSpeed {
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
