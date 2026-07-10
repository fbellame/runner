import Foundation

/// Minimal DayLedger projection consumed by GoalsMath.
struct GoalLedgerDay: Equatable, Sendable {
    let date: Date
    let isGold: Bool
    /// DayLedger.weeklyTargetAtThatTime — the target in effect when the day was ledgered.
    let weeklyTarget: Int
}

enum GoalDotState: Equatable, Sendable {
    case gold
    case missed
    case future
}

struct WeeklyGoalStatus: Equatable, Sendable {
    let goldDays: Int
    let target: Int
    /// Exactly 7 entries, Monday first.
    let dots: [GoalDotState]
    let isMet: Bool
    /// Consecutive completed weeks; the current week counts once completed.
    let streak: Int
}

struct CompletedWeek: Equatable, Sendable {
    /// Monday start-of-day of the completed week.
    let weekStart: Date
    /// The day the target-th gold day landed — when the week's goal was met.
    let completedOn: Date
}

enum GoalsMath {
    static func currentWeek(_ days: [GoalLedgerDay],
                            currentTarget: Int,
                            asOf: Date,
                            calendar: Calendar) -> WeeklyGoalStatus {
        let weekStart = WeekMath.mondayStart(for: asOf, calendar: calendar)
        let today = calendar.startOfDay(for: asOf)
        let goldDates = Set(days.filter(\.isGold).map { calendar.startOfDay(for: $0.date) })

        var dots: [GoalDotState] = []
        var goldDays = 0
        for offset in 0..<7 {
            let dayDate = calendar.date(byAdding: .day, value: offset, to: weekStart)!
            if dayDate > today {
                dots.append(.future)
            } else if goldDates.contains(dayDate) {
                dots.append(.gold)
                goldDays += 1
            } else {
                dots.append(.missed)
            }
        }

        let isMet = goldDays >= currentTarget
        let completed = Set(completedWeeks(days, calendar: calendar).map(\.weekStart))
        var streak = isMet ? 1 : 0
        var week = calendar.date(byAdding: .day, value: -7, to: weekStart)!
        while completed.contains(week) {
            streak += 1
            week = calendar.date(byAdding: .day, value: -7, to: week)!
        }

        return WeeklyGoalStatus(goldDays: goldDays, target: currentTarget,
                                dots: dots, isMet: isMet, streak: streak)
    }

    /// Every week whose unique gold days reached the weeklyTarget snapshot of its
    /// latest ledgered day. Judged from snapshots, so raising the target later
    /// never rewrites history.
    static func completedWeeks(_ days: [GoalLedgerDay], calendar: Calendar) -> [CompletedWeek] {
        let byWeek = Dictionary(grouping: days) { WeekMath.mondayStart(for: $0.date, calendar: calendar) }
        return byWeek.compactMap { weekStart, weekDays -> CompletedWeek? in
            guard let latest = weekDays.max(by: { $0.date < $1.date }) else { return nil }
            let target = max(latest.weeklyTarget, 1)
            let goldDates = Set(weekDays.filter(\.isGold).map { calendar.startOfDay(for: $0.date) }).sorted()
            guard goldDates.count >= target else { return nil }
            return CompletedWeek(weekStart: weekStart, completedOn: goldDates[target - 1])
        }
        .sorted { $0.weekStart < $1.weekStart }
    }
}
