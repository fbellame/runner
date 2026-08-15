import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct ArmedWorkoutRecorderTests {
    private let base = Date().addingTimeInterval(-2)

    private func location(x: Double, seconds: TimeInterval,
                          speed: Double) -> CLLocation {
        let longitude = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: longitude),
            altitude: 30,
            horizontalAccuracy: 5,
            verticalAccuracy: 10,
            course: 90,
            speed: speed,
            timestamp: base.addingTimeInterval(seconds)
        )
    }

    private func makeRecorder() -> WorkoutRecorder {
        let base = self.base
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("armed-recorder-\(UUID().uuidString)")
        return WorkoutRecorder(
            provider: FakeLocationProvider(),
            checkpoints: CheckpointStore(directory: directory),
            clock: { base }
        )
    }

    @Test func armedStartFreezesTheClockUntilMovement() {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)

        #expect(recorder.state == .autoPaused)
        #expect(recorder.isArmed)
        #expect(recorder.movingSeconds == 0)

        recorder.didUpdate(locations: [
            location(x: 0, seconds: 10, speed: 2),
            location(x: 4, seconds: 12, speed: 2)
        ])

        #expect(recorder.state == .recording)
        #expect(!recorder.isArmed)
        #expect(recorder.startedAt == base.addingTimeInterval(10))
        #expect(recorder.movingSeconds == 2)
    }

    @Test func secondAutoPauseCycleDoesNotRebaseStartedAt() {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 4, seconds: 3, speed: 2)
        ])
        let firstRebase = recorder.startedAt

        recorder.didUpdate(locations: [
            location(x: 4, seconds: 4, speed: 0),
            location(x: 4, seconds: 14, speed: 0)
        ])
        #expect(recorder.state == .autoPaused)

        recorder.didUpdate(locations: [
            location(x: 8, seconds: 20, speed: 2),
            location(x: 12, seconds: 23, speed: 2)
        ])

        #expect(recorder.state == .recording)
        #expect(recorder.startedAt == firstRebase)
        #expect(recorder.startedAt == base)
    }

    @Test func manualPauseIsANoOpWhileArmedAndRebaseStillHappensOnFirstMovement() {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)

        // Pausing a run that hasn't started moving yet must not do anything —
        // otherwise resumeManually() could re-enter .recording without ever
        // clearing isArmed, leaving a stale one-shot rebase to misfire later.
        recorder.pauseManually()
        #expect(recorder.state == .autoPaused)
        #expect(recorder.isArmed)

        recorder.didUpdate(locations: [
            location(x: 0, seconds: 10, speed: 2),
            location(x: 4, seconds: 12, speed: 2)
        ])

        #expect(recorder.state == .recording)
        #expect(!recorder.isArmed)
        #expect(recorder.startedAt == base.addingTimeInterval(10))
        #expect(recorder.movingSeconds == 2)
    }

    /// An armed session must still un-freeze with no Doppler speed at all —
    /// EVERY sample here carries `speed: -1` (CoreLocation's "unavailable"
    /// sentinel, e.g. a phone in a zipped pocket), so only the displacement
    /// fallback can start the run.
    ///
    /// This test used to assert that a single 4 m / 2 s sample started the run.
    /// That is the sensitivity that made the session start itself while Farid
    /// was still standing at the trailhead: over a 2 s baseline, 4 m is
    /// indistinguishable from GPS noise. The contract is now sustained
    /// displacement over `SpeedEstimator.minBaseline`, so `startedAt` lands on
    /// the sample that proved it rather than on the first twitch.
    @Test func armedSessionUnfreezesFromSustainedDisplacementWhenSensorSpeedIsUnavailable() {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)
        #expect(recorder.state == .autoPaused)

        // Nothing can be concluded before a baseline exists.
        for i in 0...4 {
            recorder.didUpdate(locations: [location(x: Double(i) * 2, seconds: Double(i), speed: -1)])
        }
        #expect(recorder.state == .autoPaused)
        #expect(recorder.isArmed)

        // t=5 is the first sample with a full 5 s baseline behind it: 10 m over
        // 5 s ⇒ 2 m/s, clearing the 1.5 m/s instant-resume speed and staying
        // under the 8 m/s plausibility ceiling.
        recorder.didUpdate(locations: [location(x: 10, seconds: 5, speed: -1)])

        #expect(recorder.state == .recording)
        #expect(!recorder.isArmed)
        #expect(recorder.startedAt == base.addingTimeInterval(5))

        // Un-frozen at t=5, so the t=7 sample credits the 2 s in between.
        recorder.didUpdate(locations: [location(x: 14, seconds: 7, speed: -1)])
        #expect(recorder.movingSeconds == 2)
    }
}
