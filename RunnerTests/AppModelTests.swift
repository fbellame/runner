import Testing
import Foundation
@testable import Runner

@MainActor
struct AppModelTests {
    private func makeModel(
        liveActivity: any LiveActivityPresenting = SilentLiveActivityPresenter()
    ) throws -> (AppModel, FakeHealthStore, CheckpointStore) {
        let health = FakeHealthStore()
        let store = try DataStore(inMemory: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: dir)
        let recorder = WorkoutRecorder(provider: FakeLocationProvider(), checkpoints: checkpoints,
                                       liveActivity: liveActivity)
        return (AppModel(store: store, health: health, recorder: recorder, checkpoints: checkpoints),
                health, checkpoints)
    }

    @Test func goalPersistsAndClamps() throws {
        UserDefaults.standard.removeObject(forKey: AppModel.goalKey)
        let (model, _, _) = try makeModel()
        #expect(model.dailyGoal == 100)

        model.dailyGoal = 130
        #expect(AppModel.storedGoal() == 130)

        model.dailyGoal = 20
        #expect(model.dailyGoal == 50)

        model.dailyGoal = 9_999
        #expect(model.dailyGoal == 500)
        UserDefaults.standard.removeObject(forKey: AppModel.goalKey)
    }

    @Test func storeFailureMessageSurfacesDegradedMode() throws {
        let (model, _, _) = try makeModel()
        #expect(model.storeFailureMessage == nil)     // healthy store: no banner
        model.storeFailureMessage = "disk full"
        #expect(model.storeFailureMessage == "disk full")
    }

    /// Regression for the whole Phase 2 spoken-cues feature being silently wired
    /// off: `WorkoutRecorder.init`'s `announcer:` parameter defaults to
    /// `SilentAnnouncer()`, and `AppModel.live()` is the ONLY production
    /// construction site. If that call site ever drops (or loses) its explicit
    /// `announcer: RunAnnouncer()` argument, every cue Phase 2 computes goes
    /// nowhere and the user hears nothing. This exercises the real production
    /// path — not a fake — so it fails exactly when that wiring regresses.
    /// `AppModel.live()` only constructs its HealthKit/SwiftData/CoreLocation
    /// dependencies here; it never requests authorization or starts updates,
    /// so this is safe to run in a unit test.
    @Test func liveRecorderUsesARealAnnouncerNotSilence() {
        let model = AppModel.live()
        #expect(!(model.recorder.announcer is SilentAnnouncer))
    }

    @Test func launchDetectsCheckpoint() async throws {
        let (model, _, checkpoints) = try makeModel()
        try checkpoints.save(SessionCheckpoint(activity: .run,
                                               startedAt: .now,
                                               movingSeconds: 60,
                                               distanceMeters: 300,
                                               route: [],
                                               splitSeconds: [],
                                               savedAt: .now))

        await model.onLaunch()

        #expect(model.pendingResume != nil)
        #expect(model.pendingResume?.activity == .run)
    }

    @Test func saveAsIsPersistsCheckpointedWorkoutWithoutResuming() async throws {
        let (model, health, checkpoints) = try makeModel()
        let start = Date().addingTimeInterval(-1_800)
        let checkpoint = SessionCheckpoint(activity: .run, startedAt: start,
                                           movingSeconds: 900, distanceMeters: 3_000,
                                           route: [], splitSeconds: [300, 300, 300],
                                           savedAt: start.addingTimeInterval(900))
        try checkpoints.save(checkpoint)
        await model.onLaunch()
        #expect(model.pendingResume != nil)

        await model.saveCheckpointedWorkout()

        let recs = try model.store.allWorkouts()
        #expect(recs.count == 1)
        #expect(recs[0].distanceMeters == 3_000)
        #expect(recs[0].movingSeconds == 900)
        #expect(recs[0].end == checkpoint.savedAt)   // ends at last known progress
        #expect(recs[0].hkSynced == true)
        #expect(health.savedWorkouts.count == 1)
        #expect(model.pendingResume == nil)          // prompt dismissed
        #expect(checkpoints.load() == nil)           // nothing left to resume
    }

    /// CRITICAL 3 regression: orphan reconciliation lives only inside
    /// `LiveActivityController.begin()`, which "Save as-is" never calls — it
    /// builds the workout straight from the checkpoint, never resuming the
    /// in-memory session. Without an explicit teardown, a Live Activity that
    /// survived a pre-crash process would stay on the lock screen forever,
    /// showing stale numbers for a run that is now saved.
    @Test func saveAsIsEndsAnyStrandedLiveActivity() async throws {
        let live = LiveActivityWiringTests.LiveActivitySpy()
        let (model, _, checkpoints) = try makeModel(liveActivity: live)
        let start = Date().addingTimeInterval(-1_800)
        let checkpoint = SessionCheckpoint(activity: .run, startedAt: start,
                                           movingSeconds: 900, distanceMeters: 3_000,
                                           route: [], splitSeconds: [300, 300, 300],
                                           savedAt: start.addingTimeInterval(900))
        try checkpoints.save(checkpoint)
        await model.onLaunch()
        #expect(model.pendingResume != nil)

        await model.saveCheckpointedWorkout()

        #expect(live.endAllSurvivingActivitiesCallCount == 1)
    }

    /// CRITICAL 3 regression, Discard side: same reasoning as
    /// `saveAsIsEndsAnyStrandedLiveActivity` above — Discard never resumes
    /// the session either, so it must end any stranded activity itself.
    @Test func discardPendingResumeEndsAnyStrandedLiveActivityAndClearsCheckpoint() async throws {
        let live = LiveActivityWiringTests.LiveActivitySpy()
        let (model, _, checkpoints) = try makeModel(liveActivity: live)
        let start = Date().addingTimeInterval(-1_800)
        let checkpoint = SessionCheckpoint(activity: .run, startedAt: start,
                                           movingSeconds: 900, distanceMeters: 3_000,
                                           route: [], splitSeconds: [300, 300, 300],
                                           savedAt: start.addingTimeInterval(900))
        try checkpoints.save(checkpoint)
        await model.onLaunch()
        #expect(model.pendingResume != nil)

        model.discardPendingResume()

        #expect(live.endAllSurvivingActivitiesCallCount == 1)
        #expect(checkpoints.load() == nil)
        #expect(model.pendingResume == nil)
    }

    @Test func storedWeeklyTargetDefaultsAndClamps() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppModel.weeklyTargetKey)
        #expect(AppModel.storedWeeklyTarget() == 3)

        defaults.set(99, forKey: AppModel.weeklyTargetKey)
        #expect(AppModel.storedWeeklyTarget() == 7)

        defaults.set(0, forKey: AppModel.weeklyTargetKey)
        #expect(AppModel.storedWeeklyTarget() == 1)

        defaults.set(5, forKey: AppModel.weeklyTargetKey)
        #expect(AppModel.storedWeeklyTarget() == 5)
        defaults.removeObject(forKey: AppModel.weeklyTargetKey)
    }

    @Test func weeklyDistanceGoalsAreOptionalAndPersistPerActivity() throws {
        let defaults = UserDefaults.standard
        for type in ActivityType.allCases {
            defaults.removeObject(forKey: AppModel.weeklyDistanceGoalKey(for: type))
            #expect(AppModel.storedWeeklyDistanceGoal(for: type) == nil)
        }

        let (model, _, _) = try makeModel()
        model.setWeeklyDistanceGoal(15, for: .run)
        model.setWeeklyDistanceGoal(42.5, for: .bike)

        #expect(model.weeklyDistanceGoal(for: .run) == 15)
        #expect(model.weeklyDistanceGoal(for: .walk) == nil)
        #expect(model.weeklyDistanceGoal(for: .bike) == 42.5)
        #expect(AppModel.storedWeeklyDistanceGoal(for: .run) == 15)
        #expect(AppModel.storedWeeklyDistanceGoal(for: .bike) == 42.5)

        model.setWeeklyDistanceGoal(nil, for: .run)
        model.setWeeklyDistanceGoal(0, for: .bike)
        #expect(model.weeklyDistanceGoal(for: .run) == nil)
        #expect(model.weeklyDistanceGoal(for: .bike) == nil)

        for type in ActivityType.allCases {
            defaults.removeObject(forKey: AppModel.weeklyDistanceGoalKey(for: type))
        }
    }

    @Test func dayChangeNotificationTriggersSync() async throws {
        let (model, health, _) = try makeModel()
        await model.onLaunch()
        // Midnight passes while the app stays open: new data must be picked up
        // without waiting for a foreground or observer event.
        health.stepsByDay = [Calendar.current.startOfDay(for: .now): 7_000]
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        var points: Int?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            points = try model.store.ledger(on: .now)?.totalPoints
            if points == 70 { break }
        }
        #expect(points == 70)
    }

    @Test func launchSyncsAndObserves() async throws {
        let (model, health, _) = try makeModel()
        health.stepsByDay = [Calendar.current.startOfDay(for: .now): 5_000]

        await model.onLaunch()

        #expect(health.observers.count == 1)
        #expect(try model.store.ledger(on: Date.now)?.totalPoints == 50)
    }
}
