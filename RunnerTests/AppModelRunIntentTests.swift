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

    @Test func lockScreenStartQueuesTheLiveRecordSheet() throws {
        let (model, _, _, _) = try makeModel()

        model.startRunFromIntent()

        #expect(model.showRecordSheet)
    }

    @Test func foregroundDoesNotPresentAnAutoStartedWalkOrIdleRecorder() async throws {
        let (idleModel, _, _, _) = try makeModel()
        await idleModel.onForeground()
        #expect(!idleModel.showRecordSheet)

        let (autoWalkModel, _, _, _) = try makeModel()
        autoWalkModel.recorder.start(activity: .walk, autoStarted: true)
        await autoWalkModel.onForeground()
        #expect(!autoWalkModel.showRecordSheet)
    }

    @Test func foregroundPresentsAnExistingManualRun() async throws {
        let (model, _, _, _) = try makeModel()
        model.recorder.start(activity: .run)

        await model.onForeground()

        #expect(model.showRecordSheet)
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

    // MARK: Phase 4 whole-phase review fixes

    private func checkpoint(distance: Double = 2_400,
                            activity: ActivityType = .run,
                            lastMovingAt: Date) -> SessionCheckpoint {
        SessionCheckpoint(activity: activity,
                          startedAt: lastMovingAt.addingTimeInterval(-570),
                          movingSeconds: 570,
                          distanceMeters: distance,
                          route: [RoutePoint(lat: 45.5, lon: -73.6,
                                             t: lastMovingAt, afterGap: false)],
                          splitSeconds: [280, 285],
                          savedAt: lastMovingAt)
    }

    /// CRITICAL 1, the reachable half. Hoisting the load to the top of
    /// `onLaunch()` closes the window only if `onLaunch()` has run at all — and
    /// a `LiveActivityIntent` can background-launch the app, so `perform()` may
    /// beat it. `canAutoStart` must therefore consult the disk, not just the
    /// in-memory flag, or a cold Start still arms over an unrecovered workout
    /// and the new session's checkpoint writes overwrite it.
    @Test func startFromIntentRefusesToArmOverAnUnrecoveredWorkout() throws {
        let (model, _, _, _) = try makeModel()
        try model.checkpoints.save(checkpoint(lastMovingAt: Date().addingTimeInterval(-30)))
        #expect(model.pendingResume == nil)   // onLaunch() has not run yet

        model.startRunFromIntent()

        #expect(model.recorder.state == .idle)
        #expect(model.pendingResume != nil)
        #expect(model.checkpoints.load()?.distanceMeters == 2_400)
    }

    /// CRITICAL 2 regression, Finish side. ActivityKit activities outlive the
    /// process, so the Lock Screen can show working-looking controls over a
    /// recorder that is freshly `.idle`. Finish must act on the checkpointed
    /// run instead of silently no-oping forever.
    @Test func finishFromIntentActsOnARunThatSurvivedProcessDeath() async throws {
        let (model, pending, _, announcements) = try makeModel()
        let lastMovingAt = Date().addingTimeInterval(-30)
        try model.checkpoints.save(checkpoint(lastMovingAt: lastMovingAt))
        #expect(model.recorder.state == .idle)

        await model.finishRunFromIntent()

        let saved = try model.store.allWorkouts()
        #expect(saved.count == 1)
        #expect(saved.first?.distanceMeters == 2_400)
        #expect(saved.first?.end == lastMovingAt)
        #expect(model.checkpoints.load() == nil)
        #expect(model.pendingResume == nil)
        #expect(pending.load()?.distanceMeters == 2_400)
        #expect(announcements.events == [.runSaved])
    }

    /// CRITICAL 2 regression, Pause side. Pause must operate on a real session
    /// rather than hitting `pauseManually()`'s no-op guard, and Resume must
    /// work afterwards.
    @Test func pauseFromIntentActsOnARunThatSurvivedProcessDeath() async throws {
        let (model, _, _, _) = try makeModel()
        try model.checkpoints.save(checkpoint(lastMovingAt: Date().addingTimeInterval(-30)))

        model.togglePauseFromIntent()

        #expect(model.recorder.state == .manuallyPaused)
        #expect(model.recorder.distanceMeters == 2_400)
        #expect(model.pendingResume == nil)

        model.togglePauseFromIntent()
        #expect(model.recorder.state == .recording)
    }

    /// CRITICAL 2, the no-data case: a Live Activity outlived its process with
    /// no recoverable session behind it. There is nothing to pause or finish,
    /// so the stale activity must be ended rather than left lying on the lock
    /// screen with controls that can never do anything.
    @Test func intentsEndAStrandedActivityWhenNoSessionCanBeRecovered() async throws {
        let live = LiveActivityWiringTests.LiveActivitySpy()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-intents-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: directory)
        let model = AppModel(
            store: try DataStore(inMemory: true),
            health: FakeHealthStore(),
            recorder: WorkoutRecorder(provider: FakeLocationProvider(),
                                      checkpoints: checkpoints,
                                      liveActivity: live),
            checkpoints: checkpoints,
            pendingCelebrations: PendingCelebrationStore(directory: directory)
        )

        await model.finishRunFromIntent()
        model.togglePauseFromIntent()

        #expect(live.endAllSurvivingActivitiesCallCount == 2)
        #expect(try model.store.allWorkouts().isEmpty)
    }

    /// CRITICAL 3 regression: the pending celebration must be durable BEFORE
    /// the long save runs, so no kill window exists in which neither the
    /// checkpoint nor the celebration can recover the run.
    @Test func finishFromIntentPersistsTheCelebrationBeforeTheSaveCompletes() async throws {
        let (model, pending, health, _) = try makeModel()
        var celebrationOnDiskDuringSave = false
        var checkpointOnDiskDuringSave = false
        health.saveHook = {
            celebrationOnDiskDuringSave = pending.load() != nil
            checkpointOnDiskDuringSave = model.checkpoints.load() != nil
        }
        try model.checkpoints.save(checkpoint(lastMovingAt: Date().addingTimeInterval(-30)))

        await model.finishRunFromIntent()

        #expect(celebrationOnDiskDuringSave)
        #expect(checkpointOnDiskDuringSave)
    }

    /// CRITICAL 5 regression, the worst failure in the phase: the local write
    /// is the durable copy. When it fails, the run exists nowhere — so the
    /// recovery checkpoint must survive and "Run saved" must NOT be spoken.
    @Test func finishFromIntentKeepsTheCheckpointAndStaysSilentWhenTheLocalSaveFails() async throws {
        let (model, pending, _, announcements) = try makeModel()
        try model.checkpoints.save(checkpoint(lastMovingAt: Date().addingTimeInterval(-30)))
        model.store.upsertFailureForTesting = NSError(domain: "SwiftData", code: 13)

        await model.finishRunFromIntent()

        #expect(model.checkpoints.load() != nil)          // the only copy survives
        #expect(model.pendingResume != nil)               // and is offered back
        #expect(pending.load() == nil)                    // no celebration for a lost run
        #expect(model.pendingCelebration == nil)
        #expect(announcements.events.isEmpty)             // never claim a save
    }

    /// CRITICAL 5's counterpart, which must NOT regress: a HealthKit-only
    /// failure still announces, because the local store is durable and the run
    /// really is safe.
    @Test func healthKitOnlyFailureStillClearsTheCheckpointAndAnnounces() async throws {
        let (model, pending, health, announcements) = try makeModel()
        health.saveError = NSError(domain: "HealthKit", code: 1)
        try model.checkpoints.save(checkpoint(lastMovingAt: Date().addingTimeInterval(-30)))

        await model.finishRunFromIntent()

        #expect(try model.store.allWorkouts().count == 1)
        #expect(model.checkpoints.load() == nil)
        #expect(pending.load() != nil)
        #expect(announcements.events == [.runSaved])
    }

    /// CRITICAL 3, duplicate side. The kill window between the local write and
    /// `checkpoints.clear()` cannot be closed with a lock, so it is made
    /// harmless instead: recovering that checkpoint through "Save as-is" must
    /// upsert the same row rather than write a second workout under a fresh id.
    @Test func recoveringAnAlreadySavedCheckpointDoesNotDuplicateIt() async throws {
        let (model, _, health, _) = try makeModel()
        let lastMovingAt = Date().addingTimeInterval(-30)
        let survivor = checkpoint(lastMovingAt: lastMovingAt)
        try model.checkpoints.save(survivor)

        await model.finishRunFromIntent()
        #expect(try model.store.allWorkouts().count == 1)
        let healthSavesAfterFirst = health.savedWorkouts.count

        // Simulate the crash window: the checkpoint outlived the save.
        try model.checkpoints.save(survivor)
        model.pendingResume = survivor
        await model.saveCheckpointedWorkout()

        #expect(try model.store.allWorkouts().count == 1)
        #expect(health.savedWorkouts.count == healthSavesAfterFirst)
    }

    /// IMPORTANT 4 regression: wave 1 correctly keeps the checkpoint when
    /// `pendingCelebrations.save` throws, but nothing used to recreate the
    /// celebration from that retained checkpoint — so a process death right
    /// after this exact failure lost the celebration forever, even though the
    /// run itself was safe. `saveCheckpointedWorkout()` — the recovery path
    /// that owns the retained checkpoint — must restore it.
    @Test func recoveringACheckpointRestoresACelebrationLostToProcessDeath() async throws {
        let checkpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-intents-\(UUID().uuidString)")
        let checkpoints = CheckpointStore(directory: checkpointDir)
        // A regular FILE (not a directory) at the celebration store's path: its
        // `createDirectory(at:)` throws "file already exists", simulating a
        // real-world celebration-write failure without needing a test seam in
        // production code.
        let blockedCelebrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-\(UUID().uuidString)")
        try Data().write(to: blockedCelebrationPath)
        let firstProcessPending = PendingCelebrationStore(directory: blockedCelebrationPath)
        let firstProcess = AppModel(
            store: try DataStore(inMemory: true), health: FakeHealthStore(),
            recorder: WorkoutRecorder(provider: FakeLocationProvider(), checkpoints: checkpoints),
            checkpoints: checkpoints, pendingCelebrations: firstProcessPending
        )
        let lastMovingAt = Date().addingTimeInterval(-30)
        try checkpoints.save(checkpoint(lastMovingAt: lastMovingAt))

        await firstProcess.finishRunFromIntent()
        // The celebration write failed; the run is durable regardless, and the
        // checkpoint was kept specifically because the celebration was not.
        #expect(firstProcessPending.load() == nil)
        #expect(checkpoints.load() != nil)

        // Process death: a fresh AppModel sharing the same on-disk checkpoint,
        // with no in-memory `pendingCelebration` left to save it — the only
        // way this run's celebration can still reach the user.
        let secondProcessPending = PendingCelebrationStore(directory: checkpointDir)
        let secondProcess = AppModel(
            store: try DataStore(inMemory: true), health: FakeHealthStore(),
            recorder: WorkoutRecorder(provider: FakeLocationProvider(), checkpoints: checkpoints),
            checkpoints: checkpoints, pendingCelebrations: secondProcessPending
        )
        secondProcess.pendingResume = checkpoints.load()

        await secondProcess.saveCheckpointedWorkout()

        #expect(secondProcess.pendingCelebration != nil)
        #expect(secondProcess.pendingCelebration?.distanceMeters == 2_400)
        #expect(secondProcessPending.load() != nil)   // durable too, not just in-memory
    }

    /// IMPORTANT 5 regression: the celebration file is written before the local
    /// save completes (CRITICAL 3's ordering), so a kill in that gap can leave
    /// a celebration file whose durable row was never confirmed written. A
    /// checkpoint for the same session still being on disk is the tell — it is
    /// only ever cleared once the durable copy landed — so the celebration must
    /// not be presented (falsely claiming `isAlreadySaved: true`) until then.
    @Test func loadingACelebrationWithAStillLiveCheckpointDefersToTheResumePrompt() async throws {
        let (model, pending, _, _) = try makeModel()
        let lastMovingAt = Date().addingTimeInterval(-30)
        let cp = checkpoint(lastMovingAt: lastMovingAt)
        try model.checkpoints.save(cp)
        let workout = RecordedWorkout(type: cp.activity, start: cp.startedAt,
                                      end: cp.savedAt, movingSeconds: cp.movingSeconds,
                                      distanceMeters: cp.distanceMeters, route: cp.route,
                                      splitSeconds: cp.splitSeconds)
        try pending.save(workout)

        await model.onLaunch()

        #expect(model.pendingCelebration == nil)   // not presented as already-saved
        #expect(model.pendingResume != nil)        // the resume prompt offers it back instead
    }

    /// Counterpart: once the checkpoint really is gone (the common case — the
    /// save completed and cleared it), a pending celebration for an unrelated
    /// or already-resolved session must still load normally.
    @Test func loadingACelebrationWithNoLiveCheckpointStillPresentsIt() async throws {
        let (model, pending, _, _) = try makeModel()
        let workout = RecordedWorkout(type: .run, start: Date(timeIntervalSince1970: 1_761_000_000),
                                      end: Date(timeIntervalSince1970: 1_761_000_600),
                                      movingSeconds: 600, distanceMeters: 2_000,
                                      route: [], splitSeconds: [])
        try pending.save(workout)

        await model.onLaunch()

        #expect(model.pendingCelebration == workout)
    }

    /// IMPORTANT 6: a dismissed celebration whose file could not be deleted
    /// must not reappear on a later launch.
    @Test func anAcknowledgedCelebrationDoesNotReappearWhenItsFileSurvives() async throws {
        let (model, pending, _, _) = try makeModel()
        let workout = RecordedWorkout(type: .run, start: Date(timeIntervalSince1970: 1_760_000_000),
                                      end: Date(timeIntervalSince1970: 1_760_000_600),
                                      movingSeconds: 600, distanceMeters: 2_000,
                                      route: [], splitSeconds: [])
        try pending.save(workout)
        model.pendingCelebration = workout
        UserDefaults.standard.set(workout.start.timeIntervalSince1970,
                                  forKey: AppModel.acknowledgedCelebrationKey)
        model.pendingCelebration = nil
        // The file survived the dismissal (a failed delete).
        try pending.save(workout)

        await model.onLaunch()

        #expect(model.pendingCelebration == nil)
        UserDefaults.standard.removeObject(forKey: AppModel.acknowledgedCelebrationKey)
    }

    /// IMPORTANT 7: the widget only renders Finish on manual-run Live
    /// Activities, but the guarantee must hold by construction at the entry
    /// point too — an auto-recorded walk stays silent, always.
    @Test func finishFromIntentRefusesAnAutoStartedWalk() async throws {
        let (model, pending, _, announcements) = try makeModel()
        model.recorder.start(activity: .walk,
                             backdatedTo: Date().addingTimeInterval(-300),
                             autoStarted: true)

        await model.finishRunFromIntent()

        #expect(model.recorder.state != .idle)
        #expect(try model.store.allWorkouts().isEmpty)
        #expect(pending.load() == nil)
        #expect(model.pendingCelebration == nil)
        #expect(announcements.events.isEmpty)
    }
}
