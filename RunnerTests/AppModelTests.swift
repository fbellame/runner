import Testing
import Foundation
@testable import Runner

@MainActor
struct AppModelTests {
    private func makeModel() throws -> (AppModel, FakeHealthStore, CheckpointStore) {
        let health = FakeHealthStore()
        let store = try DataStore(inMemory: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: dir)
        let recorder = WorkoutRecorder(provider: FakeLocationProvider(), checkpoints: checkpoints)
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
