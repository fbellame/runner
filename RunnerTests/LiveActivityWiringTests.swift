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
        var endAllSurvivingActivitiesCallCount = 0
        func begin(_ snapshot: RunActivitySnapshot) { began.append(snapshot) }
        func update(_ snapshot: RunActivitySnapshot) { updated.append(snapshot) }
        func end(_ snapshot: RunActivitySnapshot) { ended.append(snapshot) }
        func endAllSurvivingActivities() { endAllSurvivingActivitiesCallCount += 1 }
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

        // Three samples, not two: the armed→recording transition itself
        // consumes the first `resumeAfter` (3 s) of continuous movement (see
        // `AutoPauseDetector`), and the sample that crosses that threshold
        // becomes the filter's first *kept* point with nothing to diff
        // against yet — a real, non-zero distance needs a further sample
        // after the detector has already unpaused.
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2),
            location(x: 10, seconds: 6, speed: 2)
        ])
        #expect(live.updated.contains { $0.status == .recording })
        let observedDistance = recorder.distanceMeters
        #expect(observedDistance > 0)

        _ = try #require(recorder.finish(endingAt: recorder.lastMovingAt))
        #expect(live.ended.isEmpty)

        recorder.completeSave()
        #expect(live.ended.map(\.status) == [.finished])
        // Not just the status: the ended snapshot must carry the REAL final
        // stats the recorder observed, not a freshly-computed (and by then
        // zeroed-by-reset()) one.
        #expect(live.ended.last?.distanceMeters == observedDistance)
    }

    /// Covers the `discard()` precedence fix (Task 8 deviation 1): by the
    /// time `RecordView`'s discard closure runs, `finish()` has already
    /// called `reset()`, which zeroes `distanceMeters`/`movingSeconds`/etc.
    /// A `discard()` that (re-)computed a fresh snapshot instead of using
    /// the captured `lastFinishedSnapshot` would end the activity with all
    /// stats at zero — indistinguishable from correct if this test only
    /// checked `.status`, since a freshly-computed post-reset snapshot is
    /// ALSO `.finished`. Asserting the real distance is what makes it
    /// load-bearing.
    @Test func discardEndsActivityWithRealFinalStats() throws {
        let live = LiveActivitySpy()
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            clock: { base },
            liveActivity: live
        )

        recorder.start(activity: .run)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2)
        ])
        let observedDistance = recorder.distanceMeters
        #expect(observedDistance > 0)

        _ = try #require(recorder.finish(endingAt: recorder.lastMovingAt))
        recorder.discard()

        let ended = try #require(live.ended.last)
        #expect(ended.status == .finished)
        #expect(ended.distanceMeters == observedDistance)
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

    /// CRITICAL 2 regression: `completeSave()` used to guard its ENTIRE body
    /// (including `announceSaved()`) on `lastFinishedSnapshot`, which is only
    /// ever assigned for `.run` (`presentsLiveActivity` gates it to
    /// `activity == .run`). `RecordView.save(_:)` calls `completeSave()` for
    /// every activity type the UI offers, so a manual walk or bike save
    /// silently lost Phase 2's audible "Run saved" confirmation. The
    /// announcement must fire regardless; only the (here, no-op) Live
    /// Activity teardown stays conditional.
    @Test func completeSaveAnnouncesRunSavedForAManualWalkWithNoLiveActivity() throws {
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

        recorder.start(activity: .walk)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2)
        ])
        _ = try #require(recorder.finish(endingAt: recorder.lastMovingAt))

        recorder.completeSave()

        #expect(spy.events.filter { $0 == .runSaved }.count == 1)
        #expect(live.began.isEmpty)
        #expect(live.updated.isEmpty)
        #expect(live.ended.isEmpty)
    }

    /// CRITICAL 4 regression: Cancel on the authorization-denied overlay used
    /// to call only `dismiss()` — no `finish()`, no `discard()`, no `end()` —
    /// so the recorder stayed non-idle and the `.error` Live Activity was
    /// stranded on the lock screen forever. `cancelAfterAuthorizationDenial()`
    /// must end it while preserving recorded progress: the on-disk checkpoint
    /// is left in place (not cleared, unlike `discard()`) so the crash-resume
    /// prompt can still recover the workout on next launch.
    @Test func cancelAfterAuthorizationDenialEndsActivityAndPreservesCheckpoint() throws {
        let live = LiveActivitySpy()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-denied-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: dir)
        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            checkpoints: checkpoints,
            clock: { base },
            liveActivity: live
        )

        recorder.start(activity: .run)
        recorder.didUpdate(locations: [
            location(x: 0, seconds: 0, speed: 2),
            location(x: 5, seconds: 3, speed: 2)
        ])
        let observedDistance = recorder.distanceMeters
        #expect(observedDistance > 0)

        recorder.didChangeAuthorization(.denied)
        #expect(live.updated.last?.status == .error)

        recorder.cancelAfterAuthorizationDenial()

        #expect(recorder.state == .idle)
        #expect(live.ended.map(\.status) == [.finished])
        let saved = try #require(checkpoints.load())
        #expect(saved.distanceMeters == observedDistance)
    }

    /// Covers the ARMED branch of `cancelAfterAuthorizationDenial()` (the
    /// `guard !isArmed else { discardArmedSession(); return }` early exit,
    /// sibling to the non-armed path covered above): an armed session has
    /// never accepted a GPS sample, so falling through to `saveCheckpoint`
    /// would overwrite a PRIOR session's legitimate on-disk recovery copy
    /// with a bogus zero-distance checkpoint. Seeds a prior checkpoint with
    /// recognizable non-zero values, arms a fresh session, cancels after
    /// authorization denial while still armed, and asserts the on-disk
    /// checkpoint is untouched — not zeroed, not overwritten.
    @Test func cancelAfterAuthorizationDenialWhileArmedPreservesPriorCheckpoint() throws {
        let live = LiveActivitySpy()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-denied-armed-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: dir)
        let priorCheckpoint = SessionCheckpoint(
            activity: .run,
            startedAt: base.addingTimeInterval(-600),
            movingSeconds: 123,
            distanceMeters: 456,
            route: [],
            splitSeconds: [60, 60],
            savedAt: base.addingTimeInterval(-30)
        )
        try checkpoints.save(priorCheckpoint)

        let recorder = WorkoutRecorder(
            provider: FakeLocationProvider(),
            checkpoints: checkpoints,
            clock: { base },
            liveActivity: live
        )

        recorder.start(activity: .run, armed: true)
        #expect(live.began.map(\.status) == [.ready])

        recorder.didChangeAuthorization(.denied)

        recorder.cancelAfterAuthorizationDenial()

        #expect(recorder.state == .idle)
        #expect(live.ended.map(\.status) == [.finished])

        let saved = try #require(checkpoints.load())
        #expect(saved == priorCheckpoint)
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
