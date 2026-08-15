import Testing
import Foundation
@testable import Runner

@MainActor
struct StartRunIntentModelTests {
    private func makeModel() throws -> AppModel {
        let store = try DataStore(inMemory: true)
        let health = FakeHealthStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("start-intent-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        return AppModel(
            store: store,
            health: health,
            recorder: WorkoutRecorder(
                provider: FakeLocationProvider(),
                checkpoints: checkpoints
            ),
            checkpoints: checkpoints
        )
    }

    @Test func startsOneArmedRunWhenRecorderIsAvailable() throws {
        let model = try makeModel()
        #expect(model.canAutoStart)

        model.startRunFromIntent()

        #expect(model.recorder.activity == .run)
        #expect(model.recorder.state == .autoPaused)
        #expect(model.recorder.isArmed)
        #expect(!model.canAutoStart)
    }

    @Test func doesNotHijackAnExistingSessionOrPendingResume() throws {
        let model = try makeModel()
        model.recorder.start(activity: .bike)
        model.startRunFromIntent()
        #expect(model.recorder.activity == .bike)

        model.recorder.discard()
        model.pendingResume = SessionCheckpoint(
            activity: .walk,
            startedAt: .now,
            movingSeconds: 10,
            distanceMeters: 20,
            route: [],
            splitSeconds: [],
            savedAt: .now
        )
        model.startRunFromIntent()
        #expect(model.recorder.state == .idle)
    }
}
