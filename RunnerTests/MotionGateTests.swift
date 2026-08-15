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
        #expect(MotionGate().vetoesStart(at: t(0)) == false)
    }

    @Test func confidentStationaryVetoesAStart() {
        var gate = MotionGate()
        gate.observe(sample(stationary: true, at: t(0)))
        #expect(gate.vetoesStart(at: t(5)))
    }

    @Test func movementLiftsTheVeto() {
        var gate = MotionGate()
        gate.observe(sample(stationary: true, at: t(0)))
        gate.observe(sample(stationary: false, at: t(3)))
        #expect(gate.vetoesStart(at: t(5)) == false)
    }

    /// "We don't know" must never be read as "he is standing still" — the same
    /// rule `MotionSample` documents for walk detection.
    @Test func unknownOrLowConfidenceNeverVetoes() {
        var unknown = MotionGate()
        unknown.observe(sample(stationary: true, unknown: true, at: t(0)))
        #expect(unknown.vetoesStart(at: t(1)) == false)

        var unsure = MotionGate()
        unsure.observe(sample(stationary: true, lowConfidence: true, at: t(0)))
        #expect(unsure.vetoesStart(at: t(1)) == false)
    }

    /// The backstop against a dead stream: a classification that old cannot be
    /// allowed to block a start forever.
    @Test func aStaleClassificationStopsVetoing() {
        var gate = MotionGate()
        gate.observe(sample(stationary: true, at: t(0)))
        #expect(gate.vetoesStart(at: t(MotionGate.maxSampleAge)))
        #expect(gate.vetoesStart(at: t(MotionGate.maxSampleAge + 1)) == false)
    }

    @Test func clearingDropsTheVeto() {
        var gate = MotionGate()
        gate.observe(sample(stationary: true, at: t(0)))
        gate.clear()
        #expect(gate.vetoesStart(at: t(1)) == false)
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

    @Test func unauthorizedMotionLeavesBehaviourExactlyAsItWas() {
        let (rec, motion) = makeRecorder()
        motion.isAuthorized = false
        rec.start(activity: .run, armed: true)
        #expect(motion.started == false)

        for i in 0...6 { rec.didUpdate(locations: [loc(x: Double(i) * 3, t: Double(i), speed: 3.0)]) }
        #expect(rec.state == .recording)
    }
}
