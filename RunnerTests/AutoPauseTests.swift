import Testing
import Foundation
@testable import Runner

struct AutoPauseTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    @Test func runAndWalkUseAggressiveProfileConstants() {
        for activity in [ActivityType.run, .walk] {
            let detector = AutoPauseDetector(activity: activity)
            #expect(detector.pauseSpeedThreshold == 0.5)
            #expect(detector.pauseAfter == 6)
            #expect(detector.resumeAfter == 1)
            #expect(detector.instantResumeSpeed == 1.5)
            #expect(detector.maxPlausibleSpeed == 8.0)
        }
    }

    @Test func bikeUsesAggressiveProfileConstants() {
        let detector = AutoPauseDetector(activity: .bike)
        #expect(detector.pauseSpeedThreshold == 1.0)
        #expect(detector.pauseAfter == 10)
        #expect(detector.resumeAfter == 1)
        #expect(detector.instantResumeSpeed == 3.0)
        #expect(detector.maxPlausibleSpeed == 25.0)
    }

    // `#expect(d.update(…) == false)` rather than `#expect(!d.update(…))`:
    // the macro captures the receiver of a bare/negated call immutably, so the
    // mutating `update` fails to compile. The comparison form is what the rest
    // of this file has always used.
    @Test func runPausesAfterSixSecondsBelowThreshold() {
        var d = AutoPauseDetector(activity: .run)
        #expect(d.update(speed: 0.2, at: t(0)) == false)
        #expect(d.update(speed: 0.1, at: t(5)) == false)
        #expect(d.update(speed: 0.1, at: t(6)) == true)
    }

    @Test func bikePausesAfterTenSecondsBelowThreshold() {
        var d = AutoPauseDetector(activity: .bike)
        #expect(d.update(speed: 0.8, at: t(0)) == false)
        #expect(d.update(speed: 0.8, at: t(9)) == false)
        #expect(d.update(speed: 0.8, at: t(10)) == true)
    }

    @Test func resumesInstantlyAtExactInstantResumeSpeed() {
        var d = AutoPauseDetector(activity: .run, startPaused: true)
        #expect(d.update(speed: 1.5, at: t(0)) == false)
    }

    @Test func resumesAfterOneSecondAbovePauseThresholdBelowInstantThreshold() {
        var d = AutoPauseDetector(activity: .run, startPaused: true)
        #expect(d.update(speed: 0.8, at: t(0)) == true)
        #expect(d.update(speed: 0.8, at: t(1)) == false)
    }

    @Test func implausibleSpeedDoesNotInstantResumeButStillAccumulatesDwell() {
        var d = AutoPauseDetector(activity: .run, startPaused: true)
        #expect(d.update(speed: 8.1, at: t(0)) == true)
        #expect(d.update(speed: 0.8, at: t(1)) == false)
    }
}
