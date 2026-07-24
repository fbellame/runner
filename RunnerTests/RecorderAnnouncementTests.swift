import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct RecorderAnnouncementTests {
    private final class AnnouncementSpy: Announcing {
        var events: [RunAnnouncement] = []
        func announce(_ event: RunAnnouncement) {
            events.append(event)
        }
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

    @Test func fullRecorderSequenceAnnouncesEachTransitionOnce() {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            clock: { base },
            announcer: spy
        )

        recorder.start(activity: .run, armed: true)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2),
            location(x: 5, seconds: 4, speed: 0),
            location(x: 5, seconds: 14, speed: 0),
            location(x: 10, seconds: 20, speed: 2),
            location(x: 15, seconds: 23, speed: 2)
        ])
        recorder.pauseManually()
        recorder.pauseManually()
        recorder.resumeManually()
        recorder.resumeManually()

        #expect(spy.events == [
            .runStarted,
            .paused,
            .resumed,
            .paused,
            .resumed
        ])
    }

    @Test func deniedAuthorizationIsAnnouncedOnce() {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            announcer: spy
        )
        recorder.start(activity: .run, armed: true)

        recorder.didChangeAuthorization(.denied)
        recorder.didChangeAuthorization(.denied)

        #expect(spy.events == [.locationDenied])
    }

    /// Regression for the still-enabled manual pause button during `.autoPaused`:
    /// `RecordView` only disables the pause control while `isArmed`, so a user can
    /// (and, at a red light, will) tap pause after the recorder has already
    /// auto-paused and already announced `.paused` for that same real-world stop.
    /// That tap must not speak a second "Paused".
    @Test func manualPauseWhileAlreadyAutoPausedDoesNotDoubleAnnounce() {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            announcer: spy
        )

        recorder.start(activity: .run)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),   // moving
            location(x: 0, seconds: 1, speed: 0.1), // slows — starts the 10 s window
            location(x: 0, seconds: 11, speed: 0.1) // ≥10 s below threshold → auto-pause
        ])
        #expect(recorder.state == .autoPaused)
        #expect(spy.events == [.paused])            // the auto-pause already spoke once

        recorder.pauseManually()                    // still-enabled button, same real stop
        #expect(recorder.state == .manuallyPaused)
        #expect(spy.events == [.paused])             // NOT [.paused, .paused]

        recorder.resumeManually()
        #expect(spy.events == [.paused, .resumed])
    }

    @Test func armedTimeoutAnnouncesCancellationOnce() async {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            armedTimeout: .milliseconds(20),
            announcer: spy
        )
        recorder.start(activity: .run, armed: true)

        try? await Task.sleep(for: .milliseconds(60))

        #expect(spy.events == [.runCancelled])
    }
}
