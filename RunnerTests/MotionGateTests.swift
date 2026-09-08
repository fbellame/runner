import Testing
import Foundation
import CoreLocation
@testable import Runner

struct MotionGateTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    private func sample(stationary: Bool, unknown: Bool = false,
                        lowConfidence: Bool = false, at: Date) -> MotionSample {
        MotionSample(isWalking: !stationary, isUnknown: unknown,
                     isLowConfidence: lowConfidence, isStationary: stationary, at: at)
    }

    @Test func withoutAnySampleTheGateAbstains() {
        #expect(MotionGate().reason(at: t(0)) != .stationary)
    }

    /// The recorder seeds the gate by replaying CoreMotion history while the live
    /// stream is already attached, so a stale sample can arrive after a fresh one.
    @Test func anOlderSampleNeverOverwritesANewerOne() {
        var gate = MotionGate()
        gate.observe(sample(stationary: false, at: t(10)))
        gate.observe(sample(stationary: true, at: t(2)))   // replayed history, late
        #expect(gate.reason(at: t(12)) != .stationary)
        #expect(gate.reason(at: t(12)) == .moving)
    }

    /// The recorder only needs one bit (`reason(at:) == .stationary`). Seven field sessions
    /// logged 8760 samples that all said "no veto" without ever saying why.
    @Test func reasonDistinguishesEveryWayTheGateCanAbstain() {
        #expect(MotionGate().reason(at: t(0)) == .noSample)

        var unknown = MotionGate()
        unknown.observe(sample(stationary: true, unknown: true, at: t(0)))
        #expect(unknown.reason(at: t(1)) == .unknown)

        var lowConf = MotionGate()
        lowConf.observe(sample(stationary: true, lowConfidence: true, at: t(0)))
        #expect(lowConf.reason(at: t(1)) == .lowConfidence)

        var stale = MotionGate()
        stale.observe(sample(stationary: true, at: t(0)))
        #expect(stale.reason(at: t(MotionGate.maxSampleAge + 1)) == .stale)

        var moving = MotionGate()
        moving.observe(sample(stationary: false, at: t(0)))
        #expect(moving.reason(at: t(1)) == .moving)

        var still = MotionGate()
        still.observe(sample(stationary: true, at: t(0)))
        #expect(still.reason(at: t(1)) == .stationary)
    }

    @Test func confidentStationaryVetoesAStart() {
        var gate = MotionGate()
        gate.observe(sample(stationary: true, at: t(0)))
        #expect(gate.reason(at: t(5)) == .stationary)
    }

    @Test func movementLiftsTheVeto() {
        var gate = MotionGate()
        gate.observe(sample(stationary: true, at: t(0)))
        gate.observe(sample(stationary: false, at: t(3)))
        #expect(gate.reason(at: t(5)) != .stationary)
    }

    /// "We don't know" must never be read as "he is standing still" — the same
    /// rule `MotionSample` documents for walk detection.
    @Test func unknownOrLowConfidenceNeverVetoes() {
        var unknown = MotionGate()
        unknown.observe(sample(stationary: true, unknown: true, at: t(0)))
        #expect(unknown.reason(at: t(1)) != .stationary)

        var unsure = MotionGate()
        unsure.observe(sample(stationary: true, lowConfidence: true, at: t(0)))
        #expect(unsure.reason(at: t(1)) != .stationary)
    }

    /// The backstop against a dead stream: a classification that old cannot be
    /// allowed to block a start forever.
    @Test func aStaleClassificationStopsVetoing() {
        var gate = MotionGate()
        gate.observe(sample(stationary: true, at: t(0)))
        #expect(gate.reason(at: t(MotionGate.maxSampleAge)) == .stationary)
        #expect(gate.reason(at: t(MotionGate.maxSampleAge + 1)) != .stationary)
    }

    @Test func clearingDropsTheVeto() {
        var gate = MotionGate()
        gate.observe(sample(stationary: true, at: t(0)))
        gate.clear()
        #expect(gate.reason(at: t(1)) != .stationary)
    }
}

@MainActor
struct MotionVetoedRecorderTests {
    private let base = Date().addingTimeInterval(-2)

    private func loc(x: Double, t: TimeInterval, speed: Double = -1) -> CLLocation {
        let lat = 45.5
        let lon = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          altitude: 30, horizontalAccuracy: 5, verticalAccuracy: 10,
                          course: 90, speed: speed, timestamp: base.addingTimeInterval(t))
    }

    /// Accuracy past `LocationFilter.maxHorizontalAccuracy`: usable as a fix,
    /// useless as evidence of speed.
    private func blindLoc(t: TimeInterval) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: -73.6),
                   altitude: 30,
                   horizontalAccuracy: LocationFilter.maxHorizontalAccuracy + 20,
                   verticalAccuracy: 10, course: 90, speed: -1,
                   timestamp: base.addingTimeInterval(t))
    }

    private func makeRecorder() -> (WorkoutRecorder, FakeMotionActivityProvider) {
        let motion = FakeMotionActivityProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("motion-veto-\(UUID().uuidString)")
        let recorder = WorkoutRecorder(provider: FakeLocationProvider(),
                                       checkpoints: CheckpointStore(directory: dir),
                                       motion: motion)
        return (recorder, motion)
    }

    /// The residual risk the GPS fix alone cannot cover: multipath in a street
    /// canyon inventing a steady 3 m/s while he stands at the trailhead. The
    /// coprocessor knows he has not taken a step.
    @Test func confidentStationaryBlocksAFalseArmedStart() {
        let (rec, motion) = makeRecorder()
        rec.start(activity: .run, armed: true)
        motion.emit(MotionSample(isWalking: false, isUnknown: false, isLowConfidence: false,
                                 isStationary: true, at: base))

        // Doppler itself reporting a confident 3 m/s — the worst case.
        for i in 0...12 { rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i), speed: 3.0)]) }

        #expect(rec.isArmed)
        #expect(rec.state == .autoPaused)
    }

    @Test func onceHeActuallyMovesTheStartGoesThrough() {
        let (rec, motion) = makeRecorder()
        rec.start(activity: .run, armed: true)
        motion.emit(MotionSample(isWalking: false, isUnknown: false, isLowConfidence: false,
                                 isStationary: true, at: base))
        rec.didUpdate(locations: [loc(x: 0, t: 0, speed: 3.0)])
        #expect(rec.isArmed)

        motion.emit(MotionSample(isWalking: true, isUnknown: false, isLowConfidence: false,
                                 isStationary: false, at: base.addingTimeInterval(1)))
        rec.didUpdate(locations: [loc(x: 3, t: 2, speed: 3.0)])

        #expect(rec.isArmed == false)
        #expect(rec.state == .recording)
    }

    /// The gate is one-directional by design. A lagging "walking" classification
    /// must never hold a stopped run open — that was the field bug.
    @Test func motionNeverBlocksAPause() {
        let (rec, motion) = makeRecorder()
        rec.start(activity: .run)
        for i in 0...9 { rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i), speed: 3.0)]) }
        #expect(rec.state == .recording)

        // CoreMotion still insists he is walking.
        motion.emit(MotionSample(isWalking: true, isUnknown: false, isLowConfidence: false,
                                 isStationary: false, at: base.addingTimeInterval(10)))
        for i in 10...16 { rec.didUpdate(locations: [loc(x: 27, t: Double(i), speed: 0.0)]) }

        #expect(rec.state == .autoPaused)
    }

    /// The bug the field traces exposed: `startActivityUpdates` fires only on a
    /// CHANGE, so a session begun while the user is already standing still receives
    /// nothing at all and the gate abstains through the exact window it exists for.
    /// Seeding from history closes it — note this test never calls `emit`.
    @Test func seedsTheGateFromHistoryWhenTheLiveStreamSaysNothing() async throws {
        let (rec, motion) = makeRecorder()
        motion.cannedHistory = [
            MotionSample(isWalking: false, isUnknown: false, isLowConfidence: false,
                         isStationary: true, at: base)
        ]
        rec.start(activity: .run, armed: true)
        try await Task.sleep(for: .milliseconds(50))   // let the seeding task land

        #expect(motion.historyWindows.count == 1)
        for i in 0...12 { rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i), speed: 3.0)]) }

        #expect(rec.isArmed)
        #expect(rec.state == .autoPaused)
    }

    /// GPS too inaccurate to estimate speed skips the auto-pause branch entirely,
    /// while the timer keeps crediting every sample that arrives. Indoors that
    /// billed a walk that was not happening: 188 minutes for 501 m, moving time
    /// equal to elapsed time. With the coprocessor confirming stillness, the clock
    /// now stops.
    @Test func blindGpsWithAConfidentStationaryClassificationStopsTheClock() {
        let (rec, motion) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0, speed: 2.5)])
        rec.didUpdate(locations: [loc(x: 10, t: 4, speed: 2.5)])
        let credited = rec.movingSeconds
        motion.emit(MotionSample(isWalking: false, isUnknown: false, isLowConfidence: false,
                                 isStationary: true, at: base.addingTimeInterval(5)))

        // Fixes far too coarse to judge speed, for longer than the tolerance.
        for i in stride(from: 10, through: 90, by: 10) {
            rec.didUpdate(locations: [blindLoc(t: Double(i))])
        }

        #expect(rec.state == .autoPaused)
        // The clock stopped: at most the one sample interval that revealed it.
        #expect(rec.movingSeconds - credited <= WorkoutRecorder.blindPauseAfter + 10)
    }

    /// The other half: outdoors under a canyon CoreMotion says running, never
    /// stationary, so blind GPS alone must not touch the clock. Stopping stays
    /// GPS's job everywhere the coprocessor has not positively agreed.
    @Test func blindGpsAloneNeverPausesWithoutTheCoprocessorAgreeing() {
        let (rec, motion) = makeRecorder()
        rec.start(activity: .run)
        rec.didUpdate(locations: [loc(x: 0, t: 0, speed: 2.5)])
        rec.didUpdate(locations: [loc(x: 10, t: 4, speed: 2.5)])
        motion.emit(MotionSample(isWalking: true, isUnknown: false, isLowConfidence: false,
                                 isStationary: false, at: base.addingTimeInterval(5)))

        for i in stride(from: 10, through: 90, by: 10) {
            rec.didUpdate(locations: [blindLoc(t: Double(i))])
        }

        #expect(rec.state == .recording)
    }

    @Test func unauthorizedMotionLeavesBehaviourExactlyAsItWas() {
        let (rec, motion) = makeRecorder()
        motion.isAuthorized = false
        rec.start(activity: .run, armed: true)
        #expect(motion.started == false)

        for i in 0...6 { rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i), speed: 3.0)]) }
        #expect(rec.state == .recording)
    }
}
