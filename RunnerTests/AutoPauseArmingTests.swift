import Testing
import Foundation
@testable import Runner

struct AutoPauseArmingTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func t(_ seconds: TimeInterval) -> Date {
        base.addingTimeInterval(seconds)
    }

    @Test func armedDetectorStaysPausedUntilThreeContinuousMovingSeconds() {
        var detector = AutoPauseDetector(activity: .run, startPaused: true)

        #expect(detector.isPaused)
        #expect(detector.update(speed: 2.0, at: t(0)) == true)
        #expect(detector.update(speed: 2.0, at: t(2)) == true)
        #expect(detector.update(speed: 2.0, at: t(3)) == false)
    }

    @Test func armedDetectorResetsItsResumeWindowAfterABriefBlip() {
        var detector = AutoPauseDetector(activity: .run, startPaused: true)

        #expect(detector.update(speed: 2.0, at: t(0)) == true)
        #expect(detector.update(speed: 0.1, at: t(2)) == true)
        #expect(detector.update(speed: 2.0, at: t(3)) == true)
        #expect(detector.update(speed: 2.0, at: t(5)) == true)
        #expect(detector.update(speed: 2.0, at: t(6)) == false)
    }

    @Test func existingConstructionStillStartsUnpaused() {
        let detector = AutoPauseDetector(activity: .run)
        #expect(!detector.isPaused)
    }
}
