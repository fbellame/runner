import Testing
import Foundation
@testable import Runner

@MainActor
struct DataStoreTests {
    private func makeStore() throws -> DataStore { try DataStore(inMemory: true) }

    private func ledgerDay(_ offset: Int, total: Int, goal: Int = 100) -> LedgerDay {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: .now))!
        return LedgerDay(date: date, steps: total * 100,
                         breakdown: PointsBreakdown(stepPoints: total, workoutPoints: 0,
                                                    multiplier: 1.0, total: total),
                         goal: goal, isGold: total >= goal, streakAfter: total >= goal ? 1 : 0)
    }

    @Test func upsertIsIdempotentPerDay() throws {
        let store = try makeStore()
        try store.upsert([ledgerDay(0, total: 50)])
        try store.upsert([ledgerDay(0, total: 120)]) // same day, new numbers
        let today = try store.ledger(on: .now)
        #expect(today?.totalPoints == 120)
        let all = try store.ledgers(from: Calendar.current.date(byAdding: .day, value: -5, to: .now)!,
                                    through: .now)
        #expect(all.count == 1)
    }

    @Test func rangeQuerySortedAscending() throws {
        let store = try makeStore()
        try store.upsert([ledgerDay(-2, total: 10), ledgerDay(0, total: 30), ledgerDay(-1, total: 20)])
        let all = try store.ledgers(from: Calendar.current.date(byAdding: .day, value: -2, to: .now)!,
                                    through: .now)
        #expect(all.map(\.totalPoints) == [10, 20, 30])
    }

    @Test func goalProviderUsesStoredGoalForPastDaysOnly() throws {
        let store = try makeStore()
        try store.upsert([ledgerDay(-1, total: 80, goal: 70),
                          ledgerDay(0, total: 90, goal: 70)]) // today already scored under 70
        let provider = store.goalProvider(currentGoal: 150)
        let cal = Calendar.current
        #expect(provider(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: .now))!) == 70)
        // Today has a stored ledger, but a goal edit must apply to today forward:
        #expect(provider(cal.startOfDay(for: .now)) == 150)
    }

    @Test func workoutUpsertAndPendingSync() throws {
        let store = try makeStore()
        let id = UUID()
        try store.upsertWorkout(id: id, type: .run, start: .now, end: .now.addingTimeInterval(1500),
                                movingSeconds: 1500, distanceMeters: 5000, points: 75,
                                routeData: nil, splitSeconds: [300, 300, 300, 300, 300],
                                source: "runner", hkSynced: false)
        #expect(try store.pendingSync().count == 1)
        #expect(try store.allWorkouts().first?.distanceEstimated == false)
        // same id upsert flips synced without duplicating
        try store.upsertWorkout(id: id, type: .run, start: .now, end: .now.addingTimeInterval(1500),
                                movingSeconds: 1500, distanceMeters: 5000,
                                distanceEstimated: true, points: 75,
                                routeData: nil, splitSeconds: [300, 300, 300, 300, 300],
                                source: "runner", hkSynced: true)
        #expect(try store.pendingSync().isEmpty)
        #expect(try store.allWorkouts().count == 1)
        #expect(try store.allWorkouts().first?.distanceEstimated == true)
        #expect(try store.workouts(onDay: .now).count == 1)
    }

    @Test func upsertNormalizesDateToStartOfDay() throws {
        let store = try makeStore()
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 30, second: 0, of: .now)!
        let day = LedgerDay(date: noon, steps: 6_000,
                            breakdown: PointsBreakdown(stepPoints: 60, workoutPoints: 0,
                                                       multiplier: 1.0, total: 60),
                            goal: 100, isGold: false, streakAfter: 0)
        try store.upsert([day])
        #expect(try store.ledger(on: .now)?.totalPoints == 60)   // found via startOfDay key
        try store.upsert([ledgerDay(0, total: 90)])              // same calendar day, midnight date
        let all = try store.ledgers(from: cal.date(byAdding: .day, value: -1, to: .now)!,
                                    through: .now)
        #expect(all.count == 1)                                  // updated, not duplicated
        #expect(all[0].totalPoints == 90)
    }

    @Test func latestLedgerBefore() throws {
        let store = try makeStore()
        try store.upsert([ledgerDay(-3, total: 110), ledgerDay(-2, total: 120)])
        let prior = try store.latestLedger(before: Calendar.current.date(byAdding: .day, value: -1,
                                                                          to: Calendar.current.startOfDay(for: .now))!)
        #expect(prior?.totalPoints == 120)
    }

    @Test @MainActor func profileIsSingletonAndPersists() throws {
        let store = try DataStore(inMemory: true)
        let p1 = try store.profile()
        p1.weightKg = 72
        p1.isWeightManual = true
        try store.save()
        let p2 = try store.profile()
        #expect(p2.weightKg == 72)
        #expect(p2.isWeightManual == true)
        // Still exactly one row.
        #expect(try store.profileCount() == 1)
    }

    @Test @MainActor func upsertWritesDerivedDayFields() throws {
        let store = try DataStore(inMemory: true)
        let date = Calendar.current.startOfDay(for: .now)
        let day = LedgerDay(date: date, steps: 5000,
                            breakdown: PointsEngine.breakdown(steps: 5000, workouts: [], streakBefore: 0),
                            goal: 100, isGold: false, streakAfter: 0)
        try store.upsert([day], derived: [date: DayDerived(activeCalories: 210, distanceMeters: 4200, activeSeconds: 1800)])
        let row = try store.ledger(on: date)
        #expect(row?.activeCalories == 210)
        #expect(row?.distanceMeters == 4200)
        #expect(row?.activeSeconds == 1800)
    }

    @Test @MainActor func upsertPersistsHealthCalorieAndCo2Flags() throws {
        let store = try DataStore(inMemory: true)
        let id = UUID()
        let rec = try store.upsertWorkout(id: id, type: .bike, start: .now, end: .now,
                                          movingSeconds: 600, distanceMeters: 2500,
                                          points: 5, routeData: nil, splitSeconds: [],
                                          source: "external", hkSynced: true,
                                          calories: 88, caloriesFromHealth: true,
                                          co2SavedGrams: 480, co2FromHealth: true)
        #expect(rec.caloriesFromHealth == true)
        #expect(rec.co2SavedGrams == 480)
        #expect(rec.co2FromHealth == true)
    }

    @Test @MainActor func co2FieldsRefreshOnResyncButCaloriesStayFrozen() throws {
        let store = try DataStore(inMemory: true)
        let id = UUID()
        _ = try store.upsertWorkout(id: id, type: .bike, start: .now, end: .now,
                                    movingSeconds: 600, distanceMeters: 2500,
                                    points: 5, routeData: nil, splitSeconds: [],
                                    source: "external", hkSynced: true,
                                    calories: 88, caloriesFromHealth: true,
                                    co2SavedGrams: 480, co2FromHealth: false)
        // Re-sync same id with a different CO₂ figure; calories are frozen, CO₂ refreshes.
        let rec = try store.upsertWorkout(id: id, type: .bike, start: .now, end: .now,
                                          movingSeconds: 600, distanceMeters: 2500,
                                          points: 5, routeData: nil, splitSeconds: [],
                                          source: "external", hkSynced: true,
                                          calories: 200, caloriesFromHealth: false,
                                          co2SavedGrams: 500, co2FromHealth: true)
        #expect(rec.calories == 88)             // frozen (was non-zero)
        #expect(rec.caloriesFromHealth == true) // frozen alongside calories
        #expect(rec.co2SavedGrams == 500)       // refreshed
        #expect(rec.co2FromHealth == true)      // refreshed
    }
}
