import Testing
import Foundation
@testable import Runner

@MainActor
struct SyncCoordinatorTests {
    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: .now))!
    }

    private func make(goal: Int = 100) throws -> (SyncCoordinator, FakeHealthStore, DataStore) {
        let health = FakeHealthStore()
        let store = try DataStore(inMemory: true)
        let sync = SyncCoordinator(health: health, store: store, currentGoal: { goal })
        return (sync, health, store)
    }

    @Test func backfillBuildsLedgersWithStreaks() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(-2): 12_000, day(-1): 3_000, day(0): 8_450]
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .run,
                            start: day(0).addingTimeInterval(9 * 3600),
                            end: day(0).addingTimeInterval(9 * 3600 + 720),
                            movingSeconds: 700,
                            distanceMeters: 2_100, isFromThisApp: false)
        ]
        await sync.syncNow()
        #expect(sync.lastError == nil)
        // day -2: 120 pts gold; day -1: 30 pts not gold; day 0: (84+32)×1.0 = 116 gold
        #expect(try store.ledger(on: day(-2))?.totalPoints == 120)
        #expect(try store.ledger(on: day(-1))?.isGold == false)
        let today = try store.ledger(on: day(0))
        #expect(today?.totalPoints == 116)
        #expect(today?.isGold == true)
        #expect(today?.streakAfter == 1)
        // external workout cached for UI
        let cached = try store.workouts(onDay: day(0))
        #expect(cached.count == 1)
        #expect(cached[0].source == "external")
        #expect(cached[0].points == 32)
    }

    @Test func pendingWorkoutSyncsAndCountsToday() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        // a locally recorded, not-yet-synced run
        try store.upsertWorkout(id: UUID(), type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                movingSeconds: 1500, distanceMeters: 5_000, points: 75,
                                routeData: try [RoutePoint(lat: 45.5, lon: -73.6, t: .now, afterGap: false),
                                                RoutePoint(lat: 45.51, lon: -73.6, t: .now, afterGap: false)].encoded(),
                                splitSeconds: [300, 300, 300, 300, 300],
                                source: "runner", hkSynced: false)
        await sync.syncNow()
        #expect(health.savedWorkouts.count == 1)
        #expect(health.savedWorkouts[0].1 == 75)
        #expect(try store.pendingSync().isEmpty)
        // today's ledger includes the pending workout: 10 + 75 = 85
        #expect(try store.ledger(on: day(0))?.totalPoints == 85)
    }

    @Test func failedHealthSaveKeepsPendingAndContinues() async throws {
        let (sync, health, store) = try make()
        health.saveError = NSError(domain: "HK", code: 5,
                                   userInfo: [NSLocalizedDescriptionKey: "not authorized"])
        health.stepsByDay = [day(0): 10_000]
        try store.upsertWorkout(id: UUID(), type: .bike, start: day(0).addingTimeInterval(3600),
                                end: day(0).addingTimeInterval(5400),
                                movingSeconds: 1800, distanceMeters: 10_000, points: 60,
                                routeData: nil, splitSeconds: [],
                                source: "runner", hkSynced: false)
        await sync.syncNow()
        #expect(try store.pendingSync().count == 1)      // still pending
        #expect(sync.lastError != nil)
        // ledger still computed: 100 steps pts + 60 bike = 160
        #expect(try store.ledger(on: day(0))?.totalPoints == 160)
    }

    @Test func externalWorkoutKeepsDuration() async throws {
        let (sync, health, store) = try make()
        let start = day(0).addingTimeInterval(9 * 3600)
        health.stepsByDay = [day(0): 1_000]
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .run, start: start,
                            end: start.addingTimeInterval(2_700), movingSeconds: 2_640,
                            distanceMeters: 8_000, isFromThisApp: false)
        ]
        await sync.syncNow()
        let cached = try #require(try store.workouts(onDay: day(0)).first)
        #expect(cached.end == start.addingTimeInterval(2_700))   // real end, not start
        #expect(cached.movingSeconds == 2_640)                   // real duration, not 0
    }

    @Test func syncRequestedMidSyncRunsAgain() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        var reentered = false
        health.workoutsHook = { [weak sync, weak health] in
            guard let sync, let health, !reentered else { return }
            reentered = true
            // New data lands while the first sync is mid-flight; the request
            // must be queued as a trailing rerun, not silently dropped.
            health.stepsByDay = [self.day(0): 5_000]
            await sync.syncNow()
        }
        await sync.syncNow()
        #expect(reentered)
        #expect(try store.ledger(on: day(0))?.totalPoints == 50) // rerun picked up 5 000 steps
    }

    @Test func saveRecordedPersistsLocallyBeforeHealthKit() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        let workout = RecordedWorkout(type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                      end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                      movingSeconds: 1500, distanceMeters: 5_000,
                                      route: [], splitSeconds: [300, 300, 300, 300, 300])
        var pendingAtHKSaveTime = -1
        health.saveHook = {
            pendingAtHKSaveTime = (try? store.pendingSync().count) ?? -1
        }
        let failure = await sync.saveRecorded(workout)
        #expect(failure == nil)
        #expect(pendingAtHKSaveTime == 1)   // durable locally before HealthKit ran
        let all = try store.allWorkouts()
        #expect(all.count == 1)             // one record, marked synced afterwards
        #expect(all[0].hkSynced == true)
        // counted exactly once in the ledger: 10 step pts + 75 workout pts
        #expect(try store.ledger(on: day(0))?.totalPoints == 85)
    }

    @Test func saveRecordedKeepsStableIdAcrossFailureAndRetry() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        health.saveError = NSError(domain: "HK", code: 5,
                                   userInfo: [NSLocalizedDescriptionKey: "refused"])
        let workout = RecordedWorkout(type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                      end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                      movingSeconds: 1500, distanceMeters: 5_000,
                                      route: [], splitSeconds: [])
        let failure = await sync.saveRecorded(workout)
        #expect(failure != nil)
        let id = try #require(try store.allWorkouts().first?.id)
        #expect(try store.pendingSync().count == 1)
        // HealthKit recovers; the retry syncs the SAME record, no duplicate
        health.saveError = nil
        await sync.syncNow()
        let all = try store.allWorkouts()
        #expect(all.count == 1)
        #expect(all[0].id == id)
        #expect(all[0].hkSynced == true)
        #expect(try store.ledger(on: day(0))?.totalPoints == 85)
    }

    @Test func saveRecordedIgnoresReentrantDuplicate() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        let workout = RecordedWorkout(type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                      end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                      movingSeconds: 1500, distanceMeters: 5_000,
                                      route: [], splitSeconds: [])
        health.saveHook = { [weak sync, weak health] in
            // A second tap on Save while the first is in flight must be a no-op.
            health?.saveHook = nil
            await sync?.saveRecorded(workout)
        }
        await sync.saveRecorded(workout)
        #expect(health.savedWorkouts.count == 1)
        #expect(try store.allWorkouts().count == 1)
        #expect(try store.ledger(on: day(0))?.totalPoints == 85)
    }

    @Test func storedGoalsPreservedOnResync() async throws {
        let (sync, health, store) = try make(goal: 150)
        // Yesterday was finalized under goal 70.
        try store.upsert([LedgerDay(date: day(-1), steps: 8_000,
                                    breakdown: PointsBreakdown(stepPoints: 80, workoutPoints: 0,
                                                               multiplier: 1.0, total: 80),
                                    goal: 70, isGold: true, streakAfter: 1)])
        health.stepsByDay = [day(-1): 8_000, day(0): 8_000]
        await sync.syncNow()
        let yesterday = try store.ledger(on: day(-1))
        #expect(yesterday?.goalAtThatTime == 70)
        #expect(yesterday?.isGold == true)               // 80 ≥ 70 under its own goal
        #expect(try store.ledger(on: day(0))?.goalAtThatTime == 150)
    }
}
