import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct LiveActivityWiringTests {
    final class LiveActivitySpy: LiveActivityPresenting {
        var began: [RunActivitySnapshot] = []
        var updated: [RunActivitySnapshot] = []
        var ended: [RunActivitySnapshot] = []
        func begin(_ snapshot: RunActivitySnapshot) { began.append(snapshot) }
        func update(_ snapshot: RunActivitySnapshot) { updated.append(snapshot) }
        func end(_ snapshot: RunActivitySnapshot) { ended.append(snapshot) }
    }

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

    @Test func manualRunBeginsReadyAndEndsOnlyAfterSaveCompletes() throws {
        let live = LiveActivitySpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            clock: { base },
            liveActivity: live
        )

        recorder.start(activity: .run, armed: true)
        #expect(live.began.map(\.status) == [.ready])

        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2)
        ])
        #expect(live.updated.contains { $0.status == .recording })

        _ = try #require(recorder.finish(endingAt: recorder.lastMovingAt))
        #expect(live.ended.isEmpty)

        recorder.completeSave()
        #expect(live.ended.map(\.status) == [.finished])
    }

    @Test func manualWalkDoesNotOpenALiveActivity() {
        let live = LiveActivitySpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            liveActivity: live
        )
        recorder.start(activity: .walk, armed: true)
        #expect(live.began.isEmpty)
    }

    @Test func armedTimeoutEndsTheLiveActivity() async {
        let live = LiveActivitySpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            armedTimeout: .milliseconds(20),
            liveActivity: live
        )
        recorder.start(activity: .run, armed: true)

        try? await Task.sleep(for: .milliseconds(60))

        #expect(live.ended.map(\.status) == [.finished])
    }

    /// Covers the `RecordView.save(_:)` collision fix (Task 8 override 3):
    /// `completeSave()` must speak "Run saved" through the existing
    /// `announceSaved()` rather than announcing a second time, so the in-app
    /// save path never says "Run saved. Run saved."
    @Test func completeSaveAnnouncesRunSavedExactlyOnce() throws {
        final class AnnouncementSpy: Announcing {
            var events: [RunAnnouncement] = []
            func announce(_ event: RunAnnouncement) { events.append(event) }
        }
        let live = LiveActivitySpy()
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            clock: { base },
            announcer: spy,
            liveActivity: live
        )

        recorder.start(activity: .run)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2)
        ])
        _ = try #require(recorder.finish(endingAt: recorder.lastMovingAt))

        // Mirrors RecordView.save(_:): completeSave() is the ONLY call on the
        // in-app save path — announceSaved() must not also be called.
        recorder.completeSave()

        #expect(spy.events.filter { $0 == .runSaved }.count == 1)
        #expect(live.ended.map(\.status) == [.finished])
    }
}
