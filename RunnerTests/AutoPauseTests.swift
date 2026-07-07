import Testing
import Foundation
@testable import Runner

struct AutoPauseTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    @Test func pausesAfterTenSecondsBelowThresholdForRun() {
        var d = AutoPauseDetector(activity: .run)
        #expect(d.update(speed: 3.0, at: t(0)) == false)
        #expect(d.update(speed: 0.2, at: t(1)) == false)   // slow starts counting
        #expect(d.update(speed: 0.1, at: t(9)) == false)   // 8 s below — not yet
        #expect(d.update(speed: 0.1, at: t(11)) == true)   // ≥10 s below → paused
    }

    @Test func briefStopDoesNotPause() {
        var d = AutoPauseDetector(activity: .walk)
        #expect(d.update(speed: 0.1, at: t(0)) == false)
        #expect(d.update(speed: 0.1, at: t(8)) == false)
        #expect(d.update(speed: 1.5, at: t(9)) == false)   // resumed moving before 10 s
        #expect(d.update(speed: 0.1, at: t(10)) == false)  // counter restarted
        #expect(d.update(speed: 0.1, at: t(19)) == false)
        #expect(d.update(speed: 0.1, at: t(21)) == true)
    }

    @Test func resumesAfterThreeSecondsAboveThreshold() {
        var d = AutoPauseDetector(activity: .run)
        _ = d.update(speed: 0.1, at: t(0))
        #expect(d.update(speed: 0.1, at: t(10)) == true)
        #expect(d.update(speed: 2.0, at: t(20)) == true)   // above, starts resume counter
        #expect(d.update(speed: 2.0, at: t(22)) == true)   // 2 s — not yet
        #expect(d.update(speed: 2.0, at: t(23.5)) == false) // ≥3 s → resumed
    }

    @Test func bikeUsesHigherThresholdAndLongerWindow() {
        var d = AutoPauseDetector(activity: .bike)
        #expect(d.update(speed: 0.8, at: t(0)) == false)   // below 1.0 → counting
        #expect(d.update(speed: 0.8, at: t(12)) == false)  // 12 s — bike needs 15
        #expect(d.update(speed: 0.8, at: t(16)) == true)
        // 0.8 m/s would NOT pause a run detector (threshold 0.5)
        var run = AutoPauseDetector(activity: .run)
        #expect(run.update(speed: 0.8, at: t(0)) == false)
        #expect(run.update(speed: 0.8, at: t(20)) == false)
    }
}
