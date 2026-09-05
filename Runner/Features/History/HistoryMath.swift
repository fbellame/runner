import Foundation

struct DaySnapshot: Equatable {
    let date: Date
    let points: Int
    let isGold: Bool
}

enum HistoryMath {
    /// Indexes `days` by start-of-day, but only for the days that fall inside
    /// `[from, through]`.
    ///
    /// Both grid builders below draw a fixed window — 52 weeks, or the last N
    /// days — out of a ledger that now spans eight years. Indexing the whole
    /// ledger meant one `Calendar.startOfDay` per row for 3,090 rows to place
    /// 364 of them, and `Calendar` is by far the most expensive part of this
    /// file: measured on device, start-of-day over the full ledger costs ~14 ms
    /// on its own, and `heatmapWeeks` cost ~98 ms of a 2.2 s tab switch. The
    /// range test is a pair of `Date` comparisons, so the rows outside the
    /// window now cost essentially nothing.
    private static func indexed(_ days: [DaySnapshot], from: Date, through: Date,
                                calendar: Calendar) -> [Date: DaySnapshot] {
        var byDate: [Date: DaySnapshot] = [:]
        byDate.reserveCapacity(days.count)
        for day in days where day.date >= from && day.date <= through {
            byDate[calendar.startOfDay(for: day.date)] = day
        }
        return byDate
    }

    static func heatmapWeeks(days: [DaySnapshot], today: Date, weekCount: Int,
                             calendar: Calendar) -> [[DaySnapshot?]] {
        let todayStart = calendar.startOfDay(for: today)
        let currentMonday = WeekMath.mondayStart(for: todayStart, calendar: calendar)
        let firstMonday = calendar.date(byAdding: .day,
                                        value: -7 * (weekCount - 1),
                                        to: currentMonday)!
        let lastDay = calendar.date(byAdding: .day, value: 7 * weekCount, to: firstMonday)!
        // `firstMonday` is itself a rendered cell, so the window is inclusive of
        // it — a row stamped at any time on that day must still be indexed.
        let byDate = indexed(days, from: firstMonday, through: lastDay, calendar: calendar)

        var weeks: [[DaySnapshot?]] = []
        weeks.reserveCapacity(weekCount)
        for week in 0..<weekCount {
            var column: [DaySnapshot?] = []
            column.reserveCapacity(7)
            for dayOfWeek in 0..<7 {
                let date = calendar.date(byAdding: .day,
                                         value: week * 7 + dayOfWeek,
                                         to: firstMonday)!
                if date > todayStart {
                    column.append(nil)
                } else {
                    column.append(byDate[date] ?? DaySnapshot(date: date,
                                                              points: 0,
                                                              isGold: false))
                }
            }
            weeks.append(column)
        }
        return weeks
    }

    static func intensity(points: Int, goal: Int) -> Double {
        guard points > 0 else { return 0 }
        guard goal > 0 else { return 1 }
        return 0.25 + 0.75 * min(Double(points) / Double(goal), 1.0)
    }

    static func dailySeries(days: [DaySnapshot], lastN: Int, endingAt: Date,
                            calendar: Calendar) -> [DaySnapshot] {
        let end = calendar.startOfDay(for: endingAt)
        let first = calendar.date(byAdding: .day, value: -(lastN - 1), to: end)!
        let last = calendar.date(byAdding: .day, value: 1, to: end)!
        let byDate = indexed(days, from: first, through: last, calendar: calendar)

        return (0..<lastN).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: end)!
            return byDate[date] ?? DaySnapshot(date: date, points: 0, isGold: false)
        }
    }
}
