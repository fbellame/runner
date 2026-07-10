import Foundation

/// Decides, from a stream of motion samples, when a walk has been going on long
/// enough to record and when it has ended. Pure and clock-free: every decision is
/// made from the samples' own timestamps, so replaying CoreMotion history behaves
/// exactly like the live stream. Mirrors `AutoPauseDetector` in spirit — that one
/// stops the clock inside a session, this one opens and closes the session itself.
struct WalkDetector {
    enum Outcome: Equatable {
        case start(walkBeganAt: Date)
        case stop(lastWalkingAt: Date)
    }

    static let startAfter: TimeInterval = 300
    static let stopAfter: TimeInterval = 300
    /// A contrary stretch shorter than this does not break the current run.
    /// Without it, red lights would reset the walking clock every block and a
    /// session would never start; a step across the room would cancel every stop.
    static let grace: TimeInterval = 60

    private(set) var isWalkSession = false

    /// The run in progress: walking or not, and when it began.
    private var runIsWalking = false
    private var runSince: Date?
    /// Contrary evidence that has not yet lasted `grace` and so hasn't broken the run.
    private var contrarySince: Date?
    private var lastWalkingAt: Date?

    mutating func update(_ sample: MotionSample) -> Outcome? {
        // Low confidence is absence of evidence, not evidence of stillness; an
        // `unknown` classification says nothing either way. Neither may extend or
        // break a run, so both leave the machine untouched.
        guard !sample.isLowConfidence, !sample.isUnknown else { return nil }

        let now = sample.at
        if sample.isWalking { lastWalkingAt = now }

        guard let started = runSince else {
            runIsWalking = sample.isWalking
            runSince = now
            return nil
        }

        // Contrary evidence that has now outlasted the grace window ends the run.
        // The new run is backdated to where that evidence began, not to now — the
        // walk started when the user started walking, not when we noticed.
        var runStart = started
        if let contrary = contrarySince, now.timeIntervalSince(contrary) >= Self.grace {
            runIsWalking.toggle()
            runStart = contrary
            runSince = contrary
            contrarySince = nil
        }

        // The run has demonstrably lasted until `now`: anything contrary in between
        // was too brief to count. Evaluated before this sample is folded in, so a
        // long stillness is still caught by the walking sample that reveals it.
        let elapsed = now.timeIntervalSince(runStart)
        var outcome: Outcome?
        if runIsWalking, !isWalkSession, elapsed >= Self.startAfter {
            isWalkSession = true
            outcome = .start(walkBeganAt: runStart)
        } else if !runIsWalking, isWalkSession, elapsed >= Self.stopAfter {
            isWalkSession = false
            outcome = .stop(lastWalkingAt: lastWalkingAt ?? runStart)
            lastWalkingAt = nil
        }

        if sample.isWalking == runIsWalking {
            contrarySince = nil
        } else if contrarySince == nil {
            contrarySince = now
        }
        return outcome
    }
}
