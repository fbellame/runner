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
