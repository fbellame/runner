import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct AutoWalkCoordinatorTests {
    // Anchored at the real now: LocationFilter compares sample age against Date().
    private let now = Date()
    private func t(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }

    private func walking(_ s: TimeInterval) -> MotionSample {
        MotionSample(isWalking: true, isUnknown: false, isLowConfidence: false, at: t(s))
    }
    private func still(_ s: TimeInterval) -> MotionSample {
        MotionSample(isWalking: false, isUnknown: false, isLowConfidence: false, at: t(s))
    }

    private func loc(x: Double, t offset: TimeInterval, speed: Double = 1.4) -> CLLocation {
        let lon = -73.6 + x / (111_320.0 * cos(45.5 * .pi / 180))
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: lon),
                          altitude: 30, horizontalAccuracy: 5, verticalAccuracy: 10,
                          course: 90, speed: speed, timestamp: t(offset))
    }

    private final class Saved { var workouts: [RecordedWorkout] = [] }

    private final class LiveActivitySpy: LiveActivityPresenting {
        var beginCount = 0
        func begin(_ snapshot: RunActivitySnapshot) { beginCount += 1 }
        func update(_ snapshot: RunActivitySnapshot) {}
        func end(_ snapshot: RunActivitySnapshot) {}
        func endAllSurvivingActivities() {}
    }

    private struct Harness {
        let coordinator: AutoWalkCoordinator
        let motion: FakeMotionActivityProvider
        let recorder: WorkoutRecorder
        let health: FakeHealthStore
        let location: FakeLocationProvider
        let saved: Saved
        let checkpoints: CheckpointStore
    }

    private func makeHarness(canAutoStart: @escaping () -> Bool = { true },
                             saveSucceeds: Bool = true) -> Harness {
        let motion = FakeMotionActivityProvider()
        let location = FakeLocationProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autowalk-\(UUID().uuidString)", isDirectory: true)
        let checkpoints = CheckpointStore(directory: dir)
        let recorder = WorkoutRecorder(provider: location, checkpoints: checkpoints,
                                       clock: { self.now })
        let health = FakeHealthStore()
        let saved = Saved()
        let coordinator = AutoWalkCoordinator(motion: motion, recorder: recorder, health: health,
                                              checkpoints: checkpoints, clock: { self.now },
                                              canAutoStart: canAutoStart,
                                              save: { workout in
                                                  guard saveSucceeds else { return false }
                                                  saved.workouts.append(workout)
                                                  return true
                                              })
        return Harness(coordinator: coordinator, motion: motion, recorder: recorder,
                       health: health, location: location, saved: saved, checkpoints: checkpoints)
    }

    /// Walks 200 m of GPS between the start and the stop.
    private func recordSomeGPS(_ h: Harness) {
        h.recorder.didUpdate(locations: [loc(x: 0, t: -2), loc(x: 200, t: -1)])
    }

    // MARK: Start

    @Test func autoStartsAfterFiveMinutesAndBackdatesToTheWalkStart() async {
        let h = makeHarness()
        await h.coordinator.ingest(walking(-300))
        #expect(h.recorder.state == .idle)
        await h.coordinator.ingest(walking(0))
        #expect(h.recorder.state == .recording)
        #expect(h.recorder.activity == .walk)
        #expect(h.recorder.autoStarted)
        #expect(h.coordinator.isAutoSession)
        #expect(h.recorder.startedAt == t(-300))
        // The pre-detection stretch is credited as moving time up front.
        #expect(h.recorder.movingSeconds == 300)
        #expect(h.location.started)
    }

    @Test func doesNotAutoStartWhileAManualSessionIsRecording() async {
        let h = makeHarness()
        h.recorder.start(activity: .run)
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        #expect(h.recorder.activity == .run)     // the run was not hijacked
        #expect(!h.recorder.autoStarted)
        #expect(!h.coordinator.isAutoSession)
    }

    @Test func doesNotAutoStartWhileAResumeIsPending() async {
        let h = makeHarness(canAutoStart: { false })
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        #expect(h.recorder.state == .idle)
        #expect(!h.coordinator.isAutoSession)
    }

    // MARK: Stop and save

    @Test func autoStopsAtTheLastWalkingMomentAndSaves() async {
        let h = makeHarness()
        h.health.rangedWalkRunDistance = 0
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        recordSomeGPS(h)
        await h.coordinator.ingest(still(10))
        await h.coordinator.ingest(still(310))

        #expect(h.recorder.state == .idle)
        #expect(!h.coordinator.isAutoSession)
        #expect(h.saved.workouts.count == 1)
        let workout = h.saved.workouts[0]
        #expect(workout.type == .walk)
        #expect(workout.autoStarted)
        #expect(workout.start == t(-300))
        // Ends when walking stopped, not five minutes later when we noticed.
        #expect(workout.end == t(0))
        #expect(h.location.stopped)
    }

    @Test func backfillsThePreGPSDistanceFromHealthAndFlagsItEstimated() async {
        let h = makeHarness()
        h.health.rangedWalkRunDistance = 350
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        recordSomeGPS(h)
        await h.coordinator.ingest(still(10))
        await h.coordinator.ingest(still(310))

        let workout = h.saved.workouts[0]
        #expect(workout.distanceEstimated)
        #expect(workout.distanceMeters > 500)     // ~200 m GPS + 350 m from Health
        #expect(h.health.walkRunDistanceWindows.count == 1)
        // The window is exactly the stretch before GPS began.
        #expect(h.health.walkRunDistanceWindows[0].0 == t(-300))
        #expect(h.health.walkRunDistanceWindows[0].1 == now)
    }

    @Test func aGPSOnlyWalkIsNotFlaggedEstimated() async {
        let h = makeHarness()
        h.health.rangedWalkRunDistance = 0
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        recordSomeGPS(h)
        await h.coordinator.ingest(still(10))
        await h.coordinator.ingest(still(310))
        #expect(!h.saved.workouts[0].distanceEstimated)
    }

    @Test func aFailedHealthBackfillStillSavesTheGPSDistance() async {
        let h = makeHarness()
        h.health.walkRunDistanceError = NSError(domain: "hk", code: 1)
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        recordSomeGPS(h)
        await h.coordinator.ingest(still(10))
        await h.coordinator.ingest(still(310))
        #expect(h.saved.workouts.count == 1)
        #expect(!h.saved.workouts[0].distanceEstimated)
    }

    // MARK: The junk filter

    @Test func discardsAWalkTooShortToMeanAnything() async {
        let h = makeHarness()
        h.health.rangedWalkRunDistance = 0
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        // No GPS at all: a misread, or a walk around the apartment.
        await h.coordinator.ingest(still(10))
        await h.coordinator.ingest(still(310))

        #expect(h.saved.workouts.isEmpty)
        #expect(h.recorder.state == .idle)
        #expect(h.checkpoints.load() == nil)      // nothing left to prompt a resume
    }

    @Test func aShortGPSWalkRescuedByHealthDistanceIsKept() async {
        let h = makeHarness()
        h.health.rangedWalkRunDistance = 600
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        await h.coordinator.ingest(still(10))
        await h.coordinator.ingest(still(310))
        #expect(h.saved.workouts.count == 1)
        #expect(h.saved.workouts[0].distanceMeters == 600)
    }

    /// CRITICAL 1 regression (wave 2): wave 1's own C5 fix correctly retains
    /// the checkpoint when a silent auto-walk save fails, but `autoStop()`
    /// clears `isAutoSession` regardless and `finish()` leaves the recorder
    /// `.idle` — releasing every in-memory ownership guard while the
    /// checkpoint sits on disk. Without a fix, the very next walk auto-starts
    /// a fresh session whose own periodic checkpoint writes overwrite the
    /// retained one, destroying the only surviving record of the failed walk.
    @Test func aFailedSaveIsNotOverwrittenByTheNextAutoWalk() async {
        let h = makeHarness(saveSucceeds: false)
        h.health.rangedWalkRunDistance = 0
        // First walk: the silent save fails, so its checkpoint must be kept.
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        recordSomeGPS(h)
        await h.coordinator.ingest(still(10))
        await h.coordinator.ingest(still(310))
        #expect(h.saved.workouts.isEmpty)                 // the save failed
        let retained = h.checkpoints.load()
        #expect(retained != nil)                          // and its checkpoint was kept

        // A second walk begins right after — same shape as the first, offset
        // past the first walk's stop so the detector treats it as a fresh run.
        await h.coordinator.ingest(walking(320))
        await h.coordinator.ingest(walking(620))
        h.recorder.didUpdate(locations: [loc(x: 0, t: 619), loc(x: 200, t: 620)])
        await h.coordinator.ingest(still(630))
        await h.coordinator.ingest(still(930))

        // No later auto-start may overwrite the retained recovery checkpoint —
        // whether by starting a session that writes over it, or by silently
        // saving and clearing it out from under the still-unresolved first walk.
        #expect(h.checkpoints.load() == retained)
        #expect(h.saved.workouts.isEmpty)
    }

    @Test func aSavedWalkLeavesNoCheckpointBehind() async {
        let h = makeHarness()
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        recordSomeGPS(h)
        await h.coordinator.ingest(still(10))
        await h.coordinator.ingest(still(310))
        #expect(h.saved.workouts.count == 1)
        #expect(h.checkpoints.load() == nil)
    }

    // MARK: Foreground catch-up

    @Test func foregroundReplaysHistoryAndCanStartASession() async {
        let h = makeHarness()
        h.motion.cannedHistory = [walking(-600), walking(-300), walking(0)]
        await h.coordinator.onForeground()
        #expect(h.recorder.state == .recording)
        #expect(h.recorder.startedAt == t(-600))
        #expect(h.motion.started)
        #expect(h.motion.historyWindows.count == 1)
        #expect(h.motion.historyWindows[0].1 == now)
    }

    @Test func aSecondForegroundDoesNotReplayAlreadyConsumedSamples() async {
        // The same 30-minute window is re-queried on every foreground. Replaying it
        // must not re-open a walk that the detector already saw begin and end.
        let h = makeHarness()
        h.motion.cannedHistory = [walking(-900), walking(-600), still(-590), still(-290)]
        await h.coordinator.onForeground()
        #expect(h.recorder.state == .idle)        // started and stopped inside the replay
        let savedAfterFirst = h.saved.workouts.count

        await h.coordinator.onForeground()        // identical history, second time
        #expect(h.recorder.state == .idle)
        #expect(!h.coordinator.isAutoSession)
        #expect(h.saved.workouts.count == savedAfterFirst)
    }

    @Test func outOfOrderSamplesAreDropped() async {
        let h = makeHarness()
        await h.coordinator.ingest(walking(-300))
        await h.coordinator.ingest(walking(0))
        #expect(h.recorder.state == .recording)
        // A sample from before the session began must not disturb it.
        await h.coordinator.ingest(still(-100))
        #expect(h.recorder.state == .recording)
        #expect(h.coordinator.isAutoSession)
    }

    @Test func aWalkThatEndedBeforeGPSStartedKeepsAnHonestDuration() async {
        // Replayed from history: the walk ran from -900 to -600 and was over long
        // before the app opened. Moving time must not exceed the walk's own span.
        let h = makeHarness()
        h.health.rangedWalkRunDistance = 800
        h.motion.cannedHistory = [walking(-900), walking(-600), still(-590), still(-290)]
        await h.coordinator.onForeground()

        #expect(h.saved.workouts.count == 1)
        let workout = h.saved.workouts[0]
        #expect(workout.start == t(-900))
        #expect(workout.end == t(-600))
        #expect(workout.movingSeconds == 300)     // not the 900 s seeded at start
        #expect(workout.distanceEstimated)
        // The backfill window closes when the walk ended, not when GPS began.
        #expect(h.health.walkRunDistanceWindows[0].1 == t(-600))
    }

    @Test func unauthorizedMotionIsASilentNoOp() async {
        let h = makeHarness()
        h.motion.isAuthorized = false
        h.motion.cannedHistory = [walking(-600), walking(0)]
        await h.coordinator.onForeground()
        #expect(h.recorder.state == .idle)
        #expect(!h.motion.started)
        #expect(h.motion.historyWindows.isEmpty)
    }

    @Test func unavailableMotionIsASilentNoOp() async {
        let h = makeHarness()
        h.motion.isAvailable = false
        await h.coordinator.onForeground()
        await h.coordinator.requestAuthorization()
        #expect(h.recorder.state == .idle)
        #expect(!h.motion.started)
        #expect(h.motion.authorizationRequests == 0)
    }

    @Test func autoWalkStaysSilent() async {
        let motion = FakeMotionActivityProvider()
        let location = FakeLocationProvider()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autowalk-silent-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        let announcements = AnnouncementSpy()
        let liveActivity = LiveActivitySpy()
        let recorder = WorkoutRecorder(
            provider: location,
            checkpoints: checkpoints,
            clock: { self.now },
            announcer: announcements,
            liveActivity: liveActivity
        )
        let coordinator = AutoWalkCoordinator(
            motion: motion,
            recorder: recorder,
            health: FakeHealthStore(),
            checkpoints: checkpoints,
            clock: { self.now },
            canAutoStart: { true },
            save: { _ in true }
        )

        await coordinator.ingest(walking(-300))
        await coordinator.ingest(walking(0))
        #expect(recorder.state == .recording)
        #expect(recorder.autoStarted)

        // Drive a genuine stop-then-resume through the recorder's OWN
        // AutoPauseDetector during the live auto-walk session — not
        // AutoWalkCoordinator's separate 5-minute stop detection — to actually
        // exercise the two `!autoStarted`-guarded announcement branches inside
        // `ingest` (the auto-pause branch and the auto-resume/`wasArmed` branch).
        // Below the walk threshold (0.5 m/s) for the 6 s `pauseAfter` window
        // trips a genuine auto-pause; back above it for the 1 s `resumeAfter`
        // window trips a genuine auto-resume. The intermediate `recorder.state`
        // assertions prove these branches actually ran — not merely that nothing
        // threw — because `.autoPaused`/`.recording` are set only as a side effect
        // of the exact same code paths that guard the announcements.
        recorder.didUpdate(locations: [loc(x: 0, t: 0, speed: 1.4)])
        recorder.didUpdate(locations: [loc(x: 1, t: 1, speed: 0.1)])
        recorder.didUpdate(locations: [loc(x: 1, t: 11, speed: 0.1)])
        #expect(recorder.state == .autoPaused)   // genuine auto-pause fired
        recorder.didUpdate(locations: [loc(x: 1, t: 12, speed: 1.4)])
        recorder.didUpdate(locations: [loc(x: 2, t: 15, speed: 1.4)])
        #expect(recorder.state == .recording)    // genuine auto-resume fired

        #expect(announcements.events.isEmpty)
        #expect(liveActivity.beginCount == 0)
    }
}
