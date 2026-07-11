import Testing
import Foundation
@testable import Runner

struct LedgerBuilderTests {
    private func day(_ offset: Int, steps: Int, workouts: [WorkoutSummary] = []) -> DayActivity {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000)) // fixed anchor
        return DayActivity(date: cal.date(byAdding: .day, value: offset, to: base)!,
                           steps: steps, workouts: workouts)
    }

    @Test func streakGrowsAndMultiplierLagsOneDay() {
        // 3 days, all 12,000 steps = 120 pts base, goal 100.
        let days = [day(0, steps: 12_000), day(1, steps: 12_000), day(2, steps: 12_000)]
        let out = LedgerBuilder.build(days: days, goalProvider: { _ in 100 },
                                      weeklyTargetProvider: { _ in 3 }, initialStreak: 0)
        #expect(out.count == 3)
        // Day 0: multiplier ×1.0 (no prior streak), total 120, gold, streakAfter 1
        #expect(out[0].breakdown.multiplier == 1.0)
        #expect(out[0].breakdown.total == 120)
        #expect(out[0].isGold && out[0].streakAfter == 1)
        // Day 1: ×1.05 → 126, streakAfter 2
        #expect(abs(out[1].breakdown.multiplier - 1.05) < 0.0001)
        #expect(out[1].breakdown.total == 126)
        #expect(out[1].streakAfter == 2)
        // Day 2: ×1.10 → 132
        #expect(out[2].breakdown.total == 132)
        #expect(out[2].streakAfter == 3)
    }

    @Test func missedDayResetsStreak() {
        let days = [day(0, steps: 12_000), day(1, steps: 3_000), day(2, steps: 12_000)]
        let out = LedgerBuilder.build(days: days, goalProvider: { _ in 100 },
                                      weeklyTargetProvider: { _ in 3 }, initialStreak: 5)
        // Day 0 enters with streak 5 → ×1.25, total 150, streakAfter 6
        #expect(abs(out[0].breakdown.multiplier - 1.25) < 0.0001)
        #expect(out[0].streakAfter == 6)
        // Day 1: 30 pts, not gold → streakAfter 0 (multiplier was ×1.3 but total 39 < 100)
        #expect(out[1].isGold == false)
        #expect(out[1].streakAfter == 0)
        // Day 2 enters with streak 0 → ×1.0
        #expect(out[2].breakdown.multiplier == 1.0)
        #expect(out[2].streakAfter == 1)
    }

    @Test func workoutsCountTowardGold() {
        let days = [day(0, steps: 2_000, workouts: [WorkoutSummary(type: .run, distanceMeters: 6_000)])]
        let out = LedgerBuilder.build(days: days, goalProvider: { _ in 100 },
                                      weeklyTargetProvider: { _ in 3 }, initialStreak: 0)
        // 20 + 90 = 110 → gold
        #expect(out[0].breakdown.total == 110)
        #expect(out[0].isGold)
    }

    @Test func goalProviderPerDay() {
        let days = [day(0, steps: 8_000), day(1, steps: 8_000)]
        let goals: [Int] = [70, 90]
        let out = LedgerBuilder.build(days: days,
                                      goalProvider: { d in
                                          Calendar.current.dateComponents([.day], from: days[0].date, to: d).day == 0 ? goals[0] : goals[1]
                                      },
                                      weeklyTargetProvider: { _ in 3 },
                                      initialStreak: 0)
        #expect(out[0].goal == 70 && out[0].isGold)     // 80 ≥ 70
        #expect(out[1].goal == 90 && out[1].isGold == false) // 84 (80×1.05=84) < 90
    }

    @Test func emptyInput() {
        #expect(LedgerBuilder.build(days: [], goalProvider: { _ in 100 },
                                    weeklyTargetProvider: { _ in 3 }, initialStreak: 3).isEmpty)
    }

    @Test func snapshotsWeeklyTargetPerDay() {
        let days = [DayActivity(date: .now, steps: 0, workouts: [])]
        let out = LedgerBuilder.build(days: days,
                                      goalProvider: { _ in 100 },
                                      weeklyTargetProvider: { _ in 4 },
                                      initialStreak: 0)
        #expect(out.count == 1)
        #expect(out[0].weeklyTarget == 4)
    }
}
