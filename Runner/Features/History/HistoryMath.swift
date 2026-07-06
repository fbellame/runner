import Foundation

struct DaySnapshot: Equatable {
    let date: Date
    let points: Int
    let isGold: Bool
}

enum HistoryMath {
    static func heatmapWeeks(days: [DaySnapshot], today: Date, weekCount: Int,
                             calendar: Calendar) -> [[DaySnapshot?]] {
        let todayStart = calendar.startOfDay(for: today)
        let byDate = Dictionary(uniqueKeysWithValues: days.map {
            (calendar.startOfDay(for: $0.date), $0)
        })

        let weekday = calendar.component(.weekday, from: todayStart)
        let daysSinceMonday = (weekday + 5) % 7
        let currentMonday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: todayStart)!
        let firstMonday = calendar.date(byAdding: .day,
                                        value: -7 * (weekCount - 1),
                                        to: currentMonday)!

        var weeks: [[DaySnapshot?]] = []
        for week in 0..<weekCount {
            var column: [DaySnapshot?] = []
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
        let byDate = Dictionary(uniqueKeysWithValues: days.map {
            (calendar.startOfDay(for: $0.date), $0)
        })
        return (0..<lastN).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: end)!
            return byDate[date] ?? DaySnapshot(date: date, points: 0, isGold: false)
        }
    }
}
