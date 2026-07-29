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

    /// Regression for the armed-fallback bug: `lastKeptLocation` is only ever
    /// assigned once real recording starts (state == .recording), which never
    /// happens while armed — every armed sample is dropped by step 4. So the
    /// computed-speed fallback in step 2 stayed permanently 0 unless a
    /// speed-reference location survives the armed state on its own. Here
    /// EVERY sample carries `speed: -1` (CoreLocation's "unavailable" sentinel
    /// — e.g. a phone in a zipped pocket), so un-freezing can only happen via
    /// that computed fallback, never via raw sensor speed.
    @Test func armedSessionUnfreezesFromComputedSpeedWhenSensorSpeedIsUnavailable() {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)
        #expect(recorder.state == .autoPaused)

        // First sample only establishes the speed reference — no prior point
        // exists yet, so its own computed speed is necessarily 0.
        recorder.didUpdate(locations: [location(x: 0, seconds: 0, speed: -1)])
        #expect(recorder.state == .autoPaused)

        // Real displacement (4 m every 2 s ⇒ 2 m/s) computed purely from
        // timestamps/coordinates, with sensor speed unavailable on every
        // sample. 2 m/s clears the 1.5 m/s instant-resume speed and stays
        // under the 8 m/s plausibility ceiling, so the session un-freezes on
        // that first moving sample rather than waiting out a dwell window.
        recorder.didUpdate(locations: [
            location(x: 4, seconds: 2, speed: -1),
            location(x: 8, seconds: 4, speed: -1)
        ])

        #expect(recorder.state == .recording)
        #expect(!recorder.isArmed)
        #expect(recorder.startedAt == base.addingTimeInterval(2))
        // Un-frozen at t=2, so the t=4 sample credits the 2 s in between.
        #expect(recorder.movingSeconds == 2)
    }
}
