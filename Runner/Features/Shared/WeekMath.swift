import Foundation

/// Monday-based week bucketing shared by the weekly engines
/// (WeeklyRecapMath, HubMath, ActivityStats, InsightsMath, GoalsMath).
enum WeekMath {
    /// Start of day of the Monday beginning the week that contains `date`.
    static func mondayStart(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day)!
    }
}
