import Foundation

struct YearInReview {
    let year: Int
    let distanceMeters: (current: Double, previous: Double)
    let sessions: (current: Int, previous: Int)
    let movingSeconds: (current: Double, previous: Double)
    let co2SavedGrams: (current: Double, previous: Double)
    let isFirstTrackedYear: Bool

    var distanceDeltaFraction: Double? {
        fractionDelta(current: distanceMeters.current, previous: distanceMeters.previous)
    }

    var movingSecondsDeltaFraction: Double? {
        fractionDelta(current: movingSeconds.current, previous: movingSeconds.previous)
    }

    private func fractionDelta(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }
}

struct MonthlyInsightPoint: Identifiable {
    let monthStart: Date
    let distanceMeters: Double
    let avgPaceSecPerKm: Double?
    let sessions: Int

    var id: Date { monthStart }
}

struct YearMonthPoint: Identifiable {
    let monthIndex: Int
    let currentMeters: Double
    let previousMeters: Double

    var id: Int { monthIndex }
}

struct ConsistencyStats {
    let longestWeekStreak: Int
    let currentWeekStreak: Int
    let daysSinceLast: Int?
}

enum HubMath {
    static func yearInReview(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                             asOf: Date, calendar: Calendar) -> YearInReview {
        let year = calendar.component(.year, from: asOf)
        let currentStart = startOfYear(year, calendar: calendar)
        let previousStart = startOfYear(year - 1, calendar: calendar)
        let previousCutoff = calendar.date(byAdding: .year, value: -1, to: asOf)!

        let scoped = summaries.filter { $0.type == type }
        let current = scoped.filter { $0.date >= currentStart && $0.date <= asOf }
        let previous = scoped.filter { $0.date >= previousStart && $0.date <= previousCutoff }

        return YearInReview(year: year,
                            distanceMeters: (current: current.reduce(0) { $0 + $1.distanceMeters },
                                             previous: previous.reduce(0) { $0 + $1.distanceMeters }),
                            sessions: (current: current.count, previous: previous.count),
                            movingSeconds: (current: current.reduce(0) { $0 + $1.movingSeconds },
                                            previous: previous.reduce(0) { $0 + $1.movingSeconds }),
                            co2SavedGrams: (current: current.reduce(0) { $0 + $1.co2SavedGrams },
                                            previous: previous.reduce(0) { $0 + $1.co2SavedGrams }),
                            isFirstTrackedYear: !scoped.contains { $0.date < currentStart })
    }

    static func monthlySeries(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                              months: Int, endingAt: Date,
                              calendar: Calendar) -> [MonthlyInsightPoint] {
        guard months > 0 else { return [] }

        let endMonthStart = monthStart(for: endingAt, calendar: calendar)
        let monthStarts = (0..<months).map { offset in
            calendar.date(byAdding: .month, value: -(months - 1 - offset), to: endMonthStart)!
        }
        var buckets = Dictionary(uniqueKeysWithValues: monthStarts.map { ($0, MonthBucket()) })

        for summary in summaries where summary.type == type {
            let start = monthStart(for: summary.date, calendar: calendar)
            guard buckets[start] != nil else { continue }

            buckets[start]!.distanceMeters += summary.distanceMeters
            buckets[start]!.sessions += 1
            if summary.distanceMeters > 0 && summary.movingSeconds > 0 {
                buckets[start]!.pacedDistanceMeters += summary.distanceMeters
                buckets[start]!.pacedMovingSeconds += summary.movingSeconds
            }
        }

        return monthStarts.map { start in
            let bucket = buckets[start] ?? MonthBucket()
            let avgPace = bucket.pacedDistanceMeters > 0
                ? bucket.pacedMovingSeconds / (bucket.pacedDistanceMeters / 1000.0)
                : nil
            return MonthlyInsightPoint(monthStart: start,
                                       distanceMeters: bucket.distanceMeters,
                                       avgPaceSecPerKm: avgPace,
                                       sessions: bucket.sessions)
        }
    }

    static func yearMonthlyComparison(_ summaries: [ActivityWorkoutSummary],
                                      type: ActivityType, year: Int,
                                      calendar: Calendar) -> [YearMonthPoint] {
        var current = [Double](repeating: 0, count: 12)
        var previous = [Double](repeating: 0, count: 12)

        for summary in summaries where summary.type == type {
            let components = calendar.dateComponents([.year, .month], from: summary.date)
            guard let summaryYear = components.year, let month = components.month else { continue }
            if summaryYear == year {
                current[month - 1] += summary.distanceMeters
            } else if summaryYear == year - 1 {
                previous[month - 1] += summary.distanceMeters
            }
        }

        return (1...12).map { index in
            YearMonthPoint(monthIndex: index,
                           currentMeters: current[index - 1],
                           previousMeters: previous[index - 1])
        }
    }

    static func consistency(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                            asOf: Date, calendar: Calendar) -> ConsistencyStats {
        let scoped = summaries.filter { $0.type == type }
        guard !scoped.isEmpty else {
            return ConsistencyStats(longestWeekStreak: 0, currentWeekStreak: 0, daysSinceLast: nil)
        }

        let activeWeeks = Set(scoped.map { WeekMath.mondayStart(for: $0.date, calendar: calendar) })

        var longest = 0
        for week in activeWeeks {
            let previousWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: week)!
            guard !activeWeeks.contains(previousWeek) else { continue }

            var length = 1
            var cursor = week
            while true {
                let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor)!
                guard activeWeeks.contains(next) else { break }
                length += 1
                cursor = next
            }
            longest = max(longest, length)
        }

        let currentWeek = WeekMath.mondayStart(for: asOf, calendar: calendar)
        // You haven't failed the current week until it's over: an inactive
        // current week falls back to a streak ending last week.
        var streakEnd: Date?
        if activeWeeks.contains(currentWeek) {
            streakEnd = currentWeek
        } else {
            let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek)!
            if activeWeeks.contains(lastWeek) {
                streakEnd = lastWeek
            }
        }
        var currentStreak = 0
        if var cursor = streakEnd {
            while activeWeeks.contains(cursor) {
                currentStreak += 1
                cursor = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor)!
            }
        }

        let lastDate = scoped.map(\.date).max()!
        let daysSinceLast = calendar.dateComponents([.day],
                                                    from: calendar.startOfDay(for: lastDate),
                                                    to: calendar.startOfDay(for: asOf)).day

        return ConsistencyStats(longestWeekStreak: longest,
                                currentWeekStreak: currentStreak,
                                daysSinceLast: daysSinceLast)
    }

    static func monthsSpanningAll(_ summaries: [ActivityWorkoutSummary],
                                  endingAt: Date, calendar: Calendar) -> Int {
        guard let earliest = summaries.map(\.date).min() else { return 12 }

        let months = calendar.dateComponents([.month],
                                             from: monthStart(for: earliest, calendar: calendar),
                                             to: monthStart(for: endingAt, calendar: calendar)).month ?? 0
        return max(months + 1, 12)
    }

    private struct MonthBucket {
        var distanceMeters = 0.0
        var pacedDistanceMeters = 0.0
        var pacedMovingSeconds = 0.0
        var sessions = 0
    }

    private static func startOfYear(_ year: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: year, month: 1, day: 1))!
    }

    private static func monthStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }
}
