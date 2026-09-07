import Testing
import Foundation
import CoreLocation
@testable import Runner

/// Regression tests for the 2026-09-05 audit fixes. Grouped by the defect each
/// one pins rather than by the type under test, because several of these are
/// cross-file contracts (the store's rule about zero-distance rows, the sync
/// path's rule about which columns a retry may touch) and reading them together
/// is the only way to see the rule whole.
@MainActor
struct AuditFixTests {

    private func make(metrics: BodyMetrics = BodyMetrics(weightKg: 70, heightCm: 180,
                                                         sex: .male, age: 30))
        throws -> (SyncCoordinator, FakeHealthStore, DataStore) {
        let health = FakeHealthStore()
        let store = try DataStore(inMemory: true)
        let sync = SyncCoordinator(health: health, store: store, currentGoal: { 100 },
                                   currentWeeklyTarget: { 3 },
                                   metricsProvider: { metrics }, defaults: isolatedDefaults("AuditFixTests"))
        return (sync, health, store)
    }

    private func recorded(_ type: ActivityType, meters: Double,
                          autoStarted: Bool = false) -> RecordedWorkout {
        let start = Date().addingTimeInterval(-1_800)
        return RecordedWorkout(type: type, start: start, end: start.addingTimeInterval(1_500),
                               movingSeconds: 1_500, distanceMeters: meters,
                               route: [], splitSeconds: [], autoStarted: autoStarted)
    }

    // MARK: A ride Runner recorded gets the same CO₂ as one it imported

    @Test func recordedRideCarriesAvoidedCO2() async throws {
        let (sync, _, store) = try make()

        await sync.saveRecorded(recorded(.bike, meters: 10_000))

        let row = try #require(try store.allWorkouts().first)
        // Same estimator both directions. This used to fall through to
        // `upsertWorkout`'s default of 0 and stay there forever, so the workout
        // showed no CO₂ tile and contributed nothing to the lifetime total or
        // the bike hub's green-impact card — while the identical ride imported
        // from Bixi showed a real number.
        #expect(row.co2SavedGrams == CO2Estimator.avoidedGrams(type: .bike,
                                                               distanceMeters: 10_000))
        #expect(row.co2SavedGrams > 0)
    }

    @Test func recordedRunCarriesNoCO2() async throws {
        let (sync, _, store) = try make()

        await sync.saveRecorded(recorded(.run, meters: 5_000))

        // The estimator is bike-only — this is the Bixi "green impact" framing,
        // not a claim that running offsets a car trip.
        #expect(try #require(try store.allWorkouts().first).co2SavedGrams == 0)
    }

    // MARK: A HealthKit retry may not reset the columns it wasn't given

    @Test func healthKitRetryPreservesProvenanceColumns() async throws {
        let (sync, health, store) = try make()
        health.saveError = NSError(domain: "HealthKit", code: 1)

        // First save: local row lands, HealthKit refuses, so the row stays
        // `hkSynced == false` and enters `pendingSync`.
        await sync.saveRecorded(recorded(.bike, meters: 8_000, autoStarted: true))
        let before = try #require(try store.allWorkouts().first)
        #expect(before.autoStarted)
        #expect(before.co2SavedGrams > 0)
        #expect(before.hkSynced == false)

        // Second sync: HealthKit accepts, `retryPendingSaves` re-upserts.
        health.saveError = nil
        await sync.syncNow()

        let after = try #require(try store.allWorkouts().first)
        #expect(after.hkSynced)
        // The retry used to pass six of eleven columns and let the rest fall to
        // their defaults; `upsertWorkout` assigns these two unconditionally, so
        // a successful retry silently erased them.
        #expect(after.autoStarted)
        #expect(after.co2SavedGrams == before.co2SavedGrams)
    }

    // MARK: Runner's own workouts come back after a reinstall

    @Test func appSourcedHealthWorkoutIsImportedWhenNoLocalRowExists() async throws {
        let (sync, health, store) = try make()
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(3_600)
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .run, start: start,
                            end: start.addingTimeInterval(1_800),
                            movingSeconds: 1_800, distanceMeters: 6_000,
                            isFromThisApp: true)
        ]

        await sync.syncNow()

        // These were skipped outright, on the assumption that this app had
        // already written the local row at record time. After a reinstall the
        // HealthKit samples survive and the SwiftData rows do not, so every run
        // Runner ever recorded vanished from History, Routes, records and
        // badges while still counting toward points and streaks.
        let rows = try store.allWorkouts()
        #expect(rows.count == 1)
        #expect(rows.first?.distanceMeters == 6_000)
        // Provenance stays honest, and it can never re-enter `pendingSync`,
        // which requires `hkSynced == false`.
        #expect(rows.first?.source == "runner")
        #expect(rows.first?.hkSynced == true)
    }

    @Test func appSourcedHealthWorkoutDoesNotOverwriteTheRicherLocalRow() async throws {
        let (sync, health, store) = try make()
        let workout = recorded(.run, meters: 5_000)
        await sync.saveRecorded(workout)
        try store.upsertWorkout(id: SyncCoordinator.recordedWorkoutID(type: .run,
                                                                      start: workout.start),
                                type: .run, start: workout.start, end: workout.end,
                                movingSeconds: workout.movingSeconds, distanceMeters: 5_000,
                                points: 75, routeData: Data("route".utf8),
                                splitSeconds: [300, 305], source: "runner", hkSynced: true)

        // Health reports the same session, flattened: no route, no splits.
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .run, start: workout.start, end: workout.end,
                            movingSeconds: workout.movingSeconds, distanceMeters: 5_000,
                            isFromThisApp: true)
        ]
        await sync.syncNow()

        let rows = try store.allWorkouts()
        #expect(rows.count == 1)
        #expect(rows.first?.splitSeconds == [300, 305])
        #expect(rows.first?.routeData != nil)
    }

    // MARK: A 0.00 km workout is not a workout

    @Test func zeroDistanceWorkoutsArePurgedFromTheStore() throws {
        let store = try DataStore(inMemory: true)
        let start = Date()
        try store.upsertWorkout(id: UUID(), type: .run, start: start,
                                end: start.addingTimeInterval(600),
                                movingSeconds: 600, distanceMeters: 0, points: 0,
                                routeData: nil, splitSeconds: [], source: "runner",
                                hkSynced: false)
        try store.upsertWorkout(id: UUID(), type: .run, start: start.addingTimeInterval(1),
                                end: start.addingTimeInterval(600),
                                movingSeconds: 600, distanceMeters: 4_000, points: 60,
                                routeData: nil, splitSeconds: [], source: "runner",
                                hkSynced: false)

        #expect(try store.purgeZeroDistanceWorkouts() == 1)
        #expect(try store.allWorkouts().map(\.distanceMeters) == [4_000])
        // Idempotent — it runs on every sync.
        #expect(try store.purgeZeroDistanceWorkouts() == 0)
    }

    @Test func syncSkipsImportingZeroDistanceWorkouts() async throws {
        let (sync, health, store) = try make()
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(3_600)
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .run, start: start,
                            end: start.addingTimeInterval(600), movingSeconds: 600,
                            distanceMeters: 0, isFromThisApp: false)
        ]

        await sync.syncNow()

        #expect(try store.allWorkouts().isEmpty)
    }

    @Test func manualFinishRefusesASessionThatCoveredNoDistance() {
        let provider = FakeLocationProvider()
        let announcer = AnnouncementSpy()
        let recorder = WorkoutRecorder(provider: provider,
                                       checkpoints: CheckpointStore(directory: tempDirectory()),
                                       announcer: announcer)
        recorder.start(activity: .run)
        // One accepted fix: there is nothing to measure a distance against.
        recorder.didUpdate(locations: [location(lon: -73.6, at: Date())])

        #expect(recorder.finish() == nil)
        #expect(recorder.state == .idle)
        // Silence would read as a save to someone who just slid to finish.
        #expect(announcer.events == [.runCancelled])
    }

    @Test func autoWalkFinishStillAllowsZeroGPSDistanceForTheHealthBackfill() {
        let provider = FakeLocationProvider()
        let recorder = WorkoutRecorder(provider: provider,
                                       checkpoints: CheckpointStore(directory: tempDirectory()))
        let began = Date().addingTimeInterval(-600)
        recorder.start(activity: .walk, backdatedTo: began, autoStarted: true)

        // A detected walk routinely finishes with zero GPS metres — the stretch
        // before GPS was running is backfilled from Health afterwards, and
        // `AutoWalkCoordinator` applies its own 100 m floor once it has been.
        let workout = recorder.finish(endingAt: Date(), requiringDistance: false)
        #expect(workout != nil)
        #expect(workout?.distanceMeters == 0)
    }

    // MARK: An impossible split cannot become a personal record

    @Test func zeroSecondSplitsCannotWinTheFastestKilometreRecord() {
        let glitched = summary(splitSeconds: [0, 0, 0, 310])
        let honest = summary(splitSeconds: [305, 300, 298, 302])

        let records = ActivityStats.typeRecords([glitched, honest], type: .run)
        let fastest = records.first { $0.kind == .fastestOneKilometer }

        // A single GPS jump that closes several kilometre boundaries at once
        // used to pin this at 0 s forever — `Format.pace(0)` renders "—", so the
        // record row read blank — and fired a bogus achievement banner.
        #expect(fastest?.value == 298)
        #expect(fastest?.workoutID == honest.id)
    }

    @Test func aFiveKilometreWindowContainingAnImpossibleSplitIsRejected() {
        let glitched = summary(splitSeconds: [0, 300, 300, 300, 300])
        let honest = summary(splitSeconds: [320, 320, 320, 320, 320])

        let records = ActivityStats.typeRecords([glitched, honest], type: .run)
        let fastestFive = records.first { $0.kind == .fastestFiveKilometers }

        // The glitched workout's only 5 km window totals 1200 s and would beat
        // the honest 1600 s. One implausible split invalidates every window
        // containing it, not just the split itself.
        #expect(fastestFive?.value == 1_600)
        #expect(fastestFive?.workoutID == honest.id)
    }

    // MARK: Settings that clamp must still persist

    @Test func clampingADailyGoalStillWritesIt() throws {
        let defaults = isolatedDefaults("clampingADailyGoal")

        let model = try AppModel(store: DataStore(inMemory: true),
                                 health: FakeHealthStore(),
                                 recorder: WorkoutRecorder(provider: FakeLocationProvider()),
                                 checkpoints: CheckpointStore(directory: tempDirectory()),
                                 defaults: defaults)
        model.dailyGoal = 10_000

        // Swift does not re-enter an observer for an assignment made inside it,
        // so the early `return` on the clamp path skipped the persistence below
        // it: the value was clamped in memory and reverted on the next launch.
        #expect(model.dailyGoal == AppModel.goalRange.upperBound)
        #expect(AppModel.storedGoal(in: defaults) == AppModel.goalRange.upperBound)
    }

    // MARK: The cheap next-milestone path agrees with the expensive one

    @Test func nextMilestoneFromPrecomputedBadgesMatchesTheFullPass() {
        let summaries = (0..<12).map { index in
            summary(distanceMeters: 3_000, date: Date().addingTimeInterval(Double(-index) * 86_400))
        }

        let direct = TrophyMath.nextMilestone(summaries)
        let reused = TrophyMath.nextMilestone(from: TrophyMath.allBadges(summaries),
                                              hasHistory: true)

        #expect(direct?.id == reused?.id)
        #expect(TrophyMath.nextMilestone(from: TrophyMath.allBadges([]),
                                         hasHistory: false) == nil)
    }

    // MARK: Helpers

    private func summary(id: UUID = UUID(), distanceMeters: Double = 5_000,
                         date: Date = Date(), splitSeconds: [Double] = []) -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(id: id, type: .run, date: date,
                               distanceMeters: distanceMeters, movingSeconds: 1_500,
                               points: 75, calories: 300, splitSeconds: splitSeconds,
                               hasRoute: false)
    }

    private func location(lon: Double, at: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45.5, longitude: lon),
                   altitude: 30, horizontalAccuracy: 5, verticalAccuracy: 10,
                   course: 90, speed: 2, timestamp: at)
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditFixTests-\(UUID().uuidString)", isDirectory: true)
    }
}
