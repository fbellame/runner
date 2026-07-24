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

        #expect(recorder.state == .autoPaused)
        #expect(recorder.movingSeconds == 0)

        recorder.didUpdate(locations: [
            location(x: 8, seconds: 13, speed: 2)
        ])

        #expect(recorder.state == .recording)
        #expect(!recorder.isArmed)
        #expect(recorder.startedAt == base.addingTimeInterval(13))
        #expect(recorder.movingSeconds == 0)
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
        #expect(recorder.startedAt == base.addingTimeInterval(3))
    }
}
