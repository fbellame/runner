import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct WorkoutTailTrimTests {
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-trim-\(UUID().uuidString)")
        return WorkoutRecorder(
            provider: FakeLocationProvider(),
            checkpoints: CheckpointStore(directory: directory),
            clock: { base }
        )
    }

    @Test func lastMovingAtTracksTheLastAcceptedRecordingSample() throws {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2),
            location(x: 15, seconds: 7, speed: 2)
        ])
        #expect(recorder.lastMovingAt == base.addingTimeInterval(7))

        recorder.didUpdate(locations: [
            location(x: 15.2, seconds: 9, speed: 0),
            location(x: 15.2, seconds: 19, speed: 0)
        ])
        #expect(recorder.lastMovingAt == base.addingTimeInterval(7))

        let workout = try #require(
            recorder.finish(endingAt: recorder.lastMovingAt)
        )
        #expect(workout.end == base.addingTimeInterval(7))
        // The very first sample already reports 2 m/s, which clears the
        // 1.5 m/s instant-resume speed, so the armed session un-freezes at
        // t=0 instead of waiting out a dwell window — the run starts when the
        // user was actually already moving.
        #expect(workout.start == base)
        #expect(workout.movingSeconds == 7)
    }

    @Test func finishingAnArmedSessionThatNeverMovedProducesNoWorkout() {
        let recorder = makeRecorder()
        recorder.start(activity: .run, armed: true)

        #expect(recorder.finish(endingAt: recorder.lastMovingAt) == nil)
        #expect(recorder.state == .idle)
    }
}
