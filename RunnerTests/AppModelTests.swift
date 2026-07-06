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

    @Test func launchSyncsAndObserves() async throws {
        let (model, health, _) = try makeModel()
        health.stepsByDay = [Calendar.current.startOfDay(for: .now): 5_000]

        await model.onLaunch()

        #expect(health.observers.count == 1)
        #expect(try model.store.ledger(on: Date.now)?.totalPoints == 50)
    }
}
