import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct RecorderAnnouncementTests {

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

    /// Regression for the one announcement site that lacked the `!autoStarted`
    /// guard every other cue has. In production this path is unreachable for
    /// auto-walks only because of a cross-file invariant (AutoWalkCoordinator
    /// always passes a non-nil `backdatedTo`, which forces `isArmed` false, so
    /// no timeout task is ever created). This test bypasses that invariant by
    /// calling the recorder's own public API directly — exactly the kind of
    /// direct construction a future call site could do — to prove the
    /// guarantee is now enforced locally rather than depending on a second file.
    @Test func armedTimeoutNeverAnnouncesForAnAutoStartedSessionEvenIfArmedDirectly() async {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            armedTimeout: .milliseconds(20),
            announcer: spy
        )
        recorder.start(activity: .run, autoStarted: true, armed: true)

        try? await Task.sleep(for: .milliseconds(60))

        #expect(spy.events == [])
    }

    /// Covers the `.runSaved` confirmation itself. `RecordView.save` no longer
    /// calls this directly — it calls `completeSave()` (Task 8), which routes
    /// through `announceSaved()` exactly once so the in-app path never says
    /// "Run saved. Run saved." (see `LiveActivityWiringTests`). Without an
    /// audible "Run saved", the last cue a hands-free user hears on a real run
    /// — stop, stand still (Paused), unzip pocket while walking (Resumed),
    /// slide to finish — is the opposite of what happened, with no
    /// confirmation the run was captured at all.
    @Test func announceSavedSpeaksRunSavedExactlyOnce() {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(provider: FakeLocationProvider(), announcer: spy)
        recorder.start(activity: .run)

        recorder.announceSaved()

        #expect(spy.events == [.runSaved])
    }

    @Test func announcesEachKilometerOnceWithItsOwnSplit() {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            clock: { base },
            announcer: spy
        )
        recorder.start(activity: .run)

        for i in 0...210 {
            recorder.didUpdate(locations: [location(x: Double(i) * 10,
                                                    seconds: Double(i) * 3,
                                                    speed: 2)])
        }

        #expect(recorder.splitSeconds.count == 2)
        // The run average is captured live at each cue, so it cannot be
        // reconstructed here the way the splits can — assert its presence and
        // the split identity instead of a whole-event equality.
        let cues: [(km: Int, seconds: Double, average: Double?)] = spy.events.compactMap {
            guard case .kmSplit(let km, let seconds, let average) = $0 else { return nil }
            return (km, seconds, average)
        }
        #expect(spy.events.count == 2)          // nothing else was announced
        #expect(cues.map(\.km) == [1, 2])
        #expect(cues.map(\.seconds) == recorder.splitSeconds)
        #expect(cues.allSatisfy { $0.average != nil })
    }

    @Test func autoStartedSessionNeverAnnouncesKilometerSplits() {
        let spy = AnnouncementSpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            clock: { base },
            announcer: spy
        )
        recorder.start(activity: .walk, autoStarted: true)

        for i in 0...110 {
            recorder.didUpdate(locations: [location(x: Double(i) * 10,
                                                    seconds: Double(i) * 3,
                                                    speed: 2)])
        }

        #expect(recorder.splitSeconds.count == 1)
        #expect(spy.events.isEmpty)
    }

    @Test func resumeFromCheckpointDoesNotReannounceCompletedSplits() {
        let spy = AnnouncementSpy()
        let checkpoint = SessionCheckpoint(
            activity: .run,
            startedAt: base,
            movingSeconds: 640,
            distanceMeters: 2_500,
            route: [RoutePoint(lat: 45.5, lon: -73.6, t: base, afterGap: false)],
            splitSeconds: [300, 310],
            savedAt: base
        )
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            clock: { base },
            announcer: spy
        )
        recorder.start(activity: .run, resumeFrom: checkpoint)
        recorder.didUpdate(locations: [location(x: 5_000, seconds: 10, speed: 2)])

        #expect(recorder.splitSeconds == [300, 310])
        #expect(spy.events.isEmpty)
    }
}
