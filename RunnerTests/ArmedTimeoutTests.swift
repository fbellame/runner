import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct ArmedTimeoutTests {
    @Test func armedSessionCancelsAfterConfiguredTimeoutWithoutMovement() async {
        let provider = FakeLocationProvider()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("armed-timeout-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        let recorder = WorkoutRecorder(
            provider: provider,
            checkpoints: checkpoints,
            armedTimeout: .milliseconds(20)
        )

        recorder.start(activity: .run, armed: true)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(recorder.state == .idle)
        #expect(!recorder.isArmed)
        #expect(provider.stopped)
        #expect(checkpoints.load() == nil)
    }

    @Test func timeoutDoesNotCancelAfterMovementStarts() async {
        let provider = FakeLocationProvider()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("armed-timeout-moving-\(UUID().uuidString)")
        let recorder = WorkoutRecorder(
            provider: provider,
            checkpoints: CheckpointStore(directory: directory),
            armedTimeout: .milliseconds(50)
        )
        let base = Date()
        func location(_ seconds: TimeInterval) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: 45.5,
                    longitude: -73.6 + seconds / 100_000
                ),
                altitude: 30,
                horizontalAccuracy: 5,
                verticalAccuracy: 10,
                course: 90,
                speed: 2,
                timestamp: base.addingTimeInterval(seconds)
            )
        }

        recorder.start(activity: .run, armed: true)
        recorder.didUpdate(locations: [location(0), location(3)])
        try? await Task.sleep(for: .milliseconds(80))

        #expect(recorder.state == .recording)
        #expect(!recorder.isArmed)
    }
}
