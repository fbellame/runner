import Foundation

struct DayActivity: Equatable, Sendable {
    let date: Date
    let steps: Int
    let workouts: [WorkoutSummary]
}

struct LedgerDay: Equatable, Sendable {
    let date: Date
    let steps: Int
    let breakdown: PointsBreakdown
    let goal: Int
    let isGold: Bool
    let streakAfter: Int
}

enum LedgerBuilder {
    static func build(days: [DayActivity],
                      goalProvider: (Date) -> Int,
                      initialStreak: Int) -> [LedgerDay] {
        var streak = initialStreak
        var out: [LedgerDay] = []
        out.reserveCapacity(days.count)
        for day in days {
            let goal = goalProvider(day.date)
            let breakdown = PointsEngine.breakdown(steps: day.steps,
                                                   workouts: day.workouts,
                                                   streakBefore: streak)
            let isGold = breakdown.total >= goal
            streak = isGold ? streak + 1 : 0
            out.append(LedgerDay(date: day.date, steps: day.steps, breakdown: breakdown,
                                 goal: goal, isGold: isGold, streakAfter: streak))
        }
        return out
    }
}
