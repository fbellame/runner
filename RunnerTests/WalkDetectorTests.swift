import Testing
import Foundation
@testable import Runner

struct WalkDetectorTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    private func walking(_ s: TimeInterval) -> MotionSample {
        MotionSample(isWalking: true, isUnknown: false, isLowConfidence: false, at: t(s))
    }
    private func still(_ s: TimeInterval) -> MotionSample {
        MotionSample(isWalking: false, isUnknown: false, isLowConfidence: false, at: t(s))
    }
    private func unknown(_ s: TimeInterval) -> MotionSample {
        MotionSample(isWalking: false, isUnknown: true, isLowConfidence: false, at: t(s))
    }
    private func lowConfidence(_ s: TimeInterval, walking: Bool) -> MotionSample {
        MotionSample(isWalking: walking, isUnknown: false, isLowConfidence: true, at: t(s))
    }

    /// Feeds samples every `step` seconds over `range`, returning every outcome.
    private func run(_ d: inout WalkDetector, walking isWalking: Bool,
                     from: TimeInterval, to: TimeInterval,
                     step: TimeInterval = 30) -> [WalkDetector.Outcome] {
        var out: [WalkDetector.Outcome] = []
        var s = from
        while s <= to {
            let sample = isWalking ? walking(s) : still(s)
            if let outcome = d.update(sample) { out.append(outcome) }
            s += step
        }
        return out
    }

    // MARK: Start

    @Test func startsAfterFiveContinuousMinutesOfWalking() {
        var d = WalkDetector()
        #expect(d.update(walking(0)) == nil)
        #expect(d.update(walking(299)) == nil)     // 4:59 — not yet
        #expect(d.update(walking(300)) == .start(walkBeganAt: t(0)))
        #expect(d.isWalkSession)
    }

    @Test func doesNotStartTwice() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        #expect(d.update(walking(300)) == .start(walkBeganAt: t(0)))
        #expect(d.update(walking(600)) == nil)
        #expect(d.update(walking(900)) == nil)
    }

    @Test func startIsBackdatedToWhenWalkingBegan() {
        var d = WalkDetector()
        _ = d.update(still(0))
        _ = d.update(walking(120))                  // walk actually begins here
        #expect(d.update(walking(420)) == .start(walkBeganAt: t(120)))
    }

    // MARK: Grace — the walking run survives short stops

    @Test func briefStopDoesNotResetTheWalkingRun() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        _ = d.update(walking(100))
        _ = d.update(still(110))                    // traffic light
        _ = d.update(still(140))                    // 30 s < grace
        _ = d.update(walking(150))                  // walking again
        // Run still counts from t(0), so 5 min elapses at t(300).
        #expect(d.update(walking(300)) == .start(walkBeganAt: t(0)))
    }

    @Test func longStopResetsTheWalkingRun() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        _ = d.update(still(100))
        _ = d.update(still(170))                    // 70 s ≥ grace → run broken at t(100)
        _ = d.update(walking(180))                  // new run begins here
        #expect(d.update(walking(300)) == nil)      // only 120 s of the new run
        #expect(d.update(walking(480)) == .start(walkBeganAt: t(180)))
    }

    @Test func longStopIsDetectedEvenWhenTheNextSampleIsWalking() {
        // A sparse stream: no not-walking sample lands past the grace window,
        // the gap only becomes visible when walking resumes.
        var d = WalkDetector()
        _ = d.update(walking(0))
        _ = d.update(still(100))
        _ = d.update(walking(300))                  // 200 s of stillness ≥ grace
        #expect(d.update(walking(500)) == nil)      // the new run began when walking resumed
        #expect(d.update(walking(600)) == .start(walkBeganAt: t(300)))
    }

    // MARK: Stop

    @Test func stopsAfterFiveContinuousMinutesOfNotWalking() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        #expect(d.update(walking(300)) == .start(walkBeganAt: t(0)))
        _ = d.update(still(310))                    // walking ceased at t(310)
        #expect(d.update(still(500)) == nil)
        #expect(d.update(still(609)) == nil)        // 299 s — not yet
        #expect(d.update(still(610)) == .stop(lastWalkingAt: t(300)))
        #expect(!d.isWalkSession)
    }

    @Test func stopCarriesTheLastWalkingTimestampNotTheStopTime() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        _ = d.update(walking(300))
        _ = d.update(walking(400))                  // last time we saw walking
        _ = d.update(still(410))
        #expect(d.update(still(710)) == .stop(lastWalkingAt: t(400)))
    }

    @Test func briefWalkDoesNotCancelAPendingStop() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        _ = d.update(walking(300))                  // session started
        _ = d.update(still(310))                    // stillness begins
        _ = d.update(walking(400))                  // 1 sample: crossing a room
        _ = d.update(still(430))                    // walk blip was < grace
        // The not-walking run still counts from t(310) → stop at t(610).
        #expect(d.update(still(610)) == .stop(lastWalkingAt: t(400)))
    }

    @Test func sustainedWalkCancelsAPendingStop() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        _ = d.update(walking(300))
        _ = d.update(still(310))
        _ = d.update(walking(400))
        _ = d.update(walking(470))                  // 70 s of walking ≥ grace → run flips
        #expect(d.update(still(610)) == nil)        // old stop window is gone
        #expect(d.isWalkSession)
    }

    @Test func neverStopsWithoutAStart() {
        var d = WalkDetector()
        let outcomes = run(&d, walking: false, from: 0, to: 1200)
        #expect(outcomes.isEmpty)
        #expect(!d.isWalkSession)
    }

    @Test func canStartAgainAfterAStop() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        #expect(d.update(walking(300)) == .start(walkBeganAt: t(0)))
        _ = d.update(still(310))
        #expect(d.update(still(610)) == .stop(lastWalkingAt: t(300)))
        _ = d.update(walking(700))
        #expect(d.update(walking(1000)) == .start(walkBeganAt: t(700)))
    }

    // MARK: Sample quality

    @Test func unknownSamplesNeitherExtendNorBreakARun() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        #expect(d.update(unknown(100)) == nil)
        #expect(d.update(unknown(200)) == nil)
        // The walking run was never broken by the unknowns.
        #expect(d.update(walking(300)) == .start(walkBeganAt: t(0)))
    }

    @Test func unknownSamplesAloneCannotStartASession() {
        var d = WalkDetector()
        let outcomes = (0...20).compactMap { d.update(unknown(TimeInterval($0) * 30)) }
        #expect(outcomes.isEmpty)
    }

    @Test func lowConfidenceSamplesAreIgnoredEntirely() {
        var d = WalkDetector()
        _ = d.update(walking(0))
        // A low-confidence "not walking" must not be read as evidence of stopping.
        _ = d.update(lowConfidence(100, walking: false))
        _ = d.update(lowConfidence(200, walking: false))
        #expect(d.update(walking(300)) == .start(walkBeganAt: t(0)))
    }

    @Test func lowConfidenceWalkingCannotStartASession() {
        var d = WalkDetector()
        let outcomes = (0...20).compactMap { d.update(lowConfidence(TimeInterval($0) * 30, walking: true)) }
        #expect(outcomes.isEmpty)
    }

    // MARK: Replay equivalence

    @Test func replayedHistoryProducesTheSameOutcomeAsALiveStream() {
        // The detector reads sample timestamps, never a wall clock, so a batch of
        // history replayed at once must behave exactly like the live stream did.
        var live = WalkDetector()
        var replayed = WalkDetector()
        let liveOutcomes = run(&live, walking: true, from: 0, to: 600)
        let history = stride(from: 0.0, through: 600.0, by: 30).map { walking($0) }
        let replayedOutcomes = history.compactMap { replayed.update($0) }
        #expect(liveOutcomes == replayedOutcomes)
        #expect(liveOutcomes == [.start(walkBeganAt: t(0))])
    }
}
