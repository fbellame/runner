import Testing
import Foundation
import CoreLocation
@testable import Runner

@MainActor
struct AppModelRunIntentTests {
    private final class AnnouncementSpy: Announcing {
        var events: [RunAnnouncement] = []
        func announce(_ event: RunAnnouncement) { events.append(event) }
    }

    private func makeModel() throws -> (
        AppModel,
        PendingCelebrationStore,
        FakeHealthStore,
        AnnouncementSpy
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-intents-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        let pending = PendingCelebrationStore(directory: directory)
        let health = FakeHealthStore()
        let announcements = AnnouncementSpy()
        let model = AppModel(
            store: try DataStore(inMemory: true),
            health: health,
            recorder: WorkoutRecorder(
                provider: FakeLocationProvider(),
                checkpoints: checkpoints,
                announcer: announcements
            ),
            checkpoints: checkpoints,
            pendingCelebrations: pending
        )
        return (model, pending, health, announcements)
    }

    @Test func togglePausesAndResumesButDoesNothingWhileArmed() throws {
        let (model, _, _, _) = try makeModel()
        model.startRunFromIntent()
        model.togglePauseFromIntent()
        #expect(model.recorder.isArmed)
        #expect(model.recorder.state == .autoPaused)

        model.recorder.discard()
        model.recorder.start(activity: .run)
        model.togglePauseFromIntent()
        #expect(model.recorder.state == .manuallyPaused)
        model.togglePauseFromIntent()
        #expect(model.recorder.state == .recording)
    }

    @Test func finishTrimsSavesPersistsAndClearsCheckpoint() async throws {
        let (model, pending, _, announcements) = try makeModel()
        let end = Date()
        model.startRunFromIntent()
        model.recorder.didUpdate(locations: [
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: -73.6),
                altitude: 30,
                horizontalAccuracy: 5,
                verticalAccuracy: 10,
                course: 90,
                speed: 2,
                timestamp: end.addingTimeInterval(-3)
            ),
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: -73.5999),
                altitude: 30,
                horizontalAccuracy: 5,
                verticalAccuracy: 10,
                course: 90,
                speed: 2,
                timestamp: end
            )
        ])

        await model.finishRunFromIntent()

        #expect(model.recorder.state == .idle)
        #expect(model.checkpoints.load() == nil)
        #expect(pending.load()?.end == end)
        #expect(model.pendingCelebration?.end == end)
        #expect(try model.store.allWorkouts().count == 1)
        #expect(announcements.events == [.runStarted, .runSaved])
    }

    @Test func healthFailureStillSavesLocallyAndAnnouncesSaved() async throws {
        let (model, pending, health, announcements) = try makeModel()
        health.saveError = NSError(domain: "HealthKit", code: 1)
        let end = Date()
        model.recorder.start(activity: .run)
        model.recorder.didUpdate(locations: [
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: -73.6),
                altitude: 30,
                horizontalAccuracy: 5,
                verticalAccuracy: 10,
                course: 90,
                speed: 2,
                timestamp: end
            )
        ])

        await model.finishRunFromIntent()

        #expect(try model.store.allWorkouts().count == 1)
        #expect(pending.load() != nil)
        #expect(announcements.events == [.runSaved])
    }
}
