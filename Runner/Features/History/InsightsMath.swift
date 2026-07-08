import Foundation

struct WeeklyInsightPoint: Identifiable {
    let weekStart: Date
    let distanceMeters: Double
    let avgPaceSecPerKm: Double?
    let sessions: Int

    var id: Date { weekStart }
}

struct PeriodComparison {
    let distanceMeters: (current: Double, previous: Double)
    let sessions: (current: Int, previous: Int)
    let movingSeconds: (current: Double, previous: Double)
    let weeksPerPeriod: Int

    var distanceDeltaFraction: Double? {
        fractionDelta(current: distanceMeters.current, previous: distanceMeters.previous)
    }

    var movingSecondsDeltaFraction: Double? {
        fractionDelta(current: movingSeconds.current, previous: movingSeconds.previous)
    }

    var sessionsPerWeekCurrent: Double {
        Double(sessions.current) / Double(weeksPerPeriod)
    }

    var sessionsPerWeekPrevious: Double {
        Double(sessions.previous) / Double(weeksPerPeriod)
    }

    var sessionsPerWeekDelta: Double {
        sessionsPerWeekCurrent - sessionsPerWeekPrevious
    }

    private func fractionDelta(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }
}

enum TrendDirection: Equatable {
    case improving
    case steady
    case declining
    case insufficientData
}

struct InsightSummary {
    let sessionsPerWeek: Double
    let sessionsPerWeekPrevious: Double
    let paceTrend: TrendDirection
    let paceDeltaSecPerKm: Double?
    let distanceTrend: TrendDirection
    let hasEnoughData: Bool
}

enum InsightsMath {
    private static let paceTrendBandSecPerKm = 3.0
    private static let distanceTrendBandFraction = 0.10
    private static let summaryWeeksPerPeriod = 4
    private static let chartWindowWeeks = 12

    static func weeklySeries(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                             weeks: Int, endingAt: Date,
                             calendar: Calendar) -> [WeeklyInsightPoint] {
        guard weeks > 0 else { return [] }

        let endWeekStart = mondayStart(for: endingAt, calendar: calendar)
        let firstWeekStart = calendar.date(byAdding: .weekOfYear,
                                           value: -(weeks - 1),
                                           to: endWeekStart)!
        let weekStarts = (0..<weeks).map { offset in
            calendar.date(byAdding: .weekOfYear, value: offset, to: firstWeekStart)!
        }
        let validWeekStarts = Set(weekStarts)

        var buckets = Dictionary(uniqueKeysWithValues: weekStarts.map {
            ($0, WeekBucket())
        })

        for summary in summaries where summary.type == type {
            let weekStart = mondayStart(for: summary.date, calendar: calendar)
            guard validWeekStarts.contains(weekStart) else { continue }

            buckets[weekStart, default: WeekBucket()].distanceMeters += summary.distanceMeters
            buckets[weekStart, default: WeekBucket()].sessions += 1

            if summary.distanceMeters > 0 && summary.movingSeconds > 0 {
                buckets[weekStart, default: WeekBucket()].pacedDistanceMeters += summary.distanceMeters
                buckets[weekStart, default: WeekBucket()].pacedMovingSeconds += summary.movingSeconds
            }
        }

        return weekStarts.map { weekStart in
            let bucket = buckets[weekStart] ?? WeekBucket()
            let avgPace: Double?
            if bucket.pacedDistanceMeters > 0 {
                avgPace = bucket.pacedMovingSeconds / (bucket.pacedDistanceMeters / 1000.0)
            } else {
                avgPace = nil
            }
            return WeeklyInsightPoint(weekStart: weekStart,
                                      distanceMeters: bucket.distanceMeters,
                                      avgPaceSecPerKm: avgPace,
                                      sessions: bucket.sessions)
        }
    }

    static func periodComparison(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                                 weeksPerPeriod: Int, endingAt: Date,
                                 calendar: Calendar) -> PeriodComparison {
        let safeWeeks = max(weeksPerPeriod, 1)
        let ranges = periodRanges(weeksPerPeriod: safeWeeks,
                                  endingAt: endingAt,
                                  calendar: calendar)
        let current = totals(summaries,
                             type: type,
                             start: ranges.current.start,
                             end: ranges.current.end)
        let previous = totals(summaries,
                              type: type,
                              start: ranges.previous.start,
                              end: ranges.previous.end)

        return PeriodComparison(distanceMeters: (current: current.distanceMeters,
                                                 previous: previous.distanceMeters),
                                sessions: (current: current.sessions,
                                           previous: previous.sessions),
                                movingSeconds: (current: current.movingSeconds,
                                                previous: previous.movingSeconds),
                                weeksPerPeriod: safeWeeks)
    }

    static func summary(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                        endingAt: Date, calendar: Calendar) -> InsightSummary {
        let comparison = periodComparison(summaries,
                                          type: type,
                                          weeksPerPeriod: summaryWeeksPerPeriod,
                                          endingAt: endingAt,
                                          calendar: calendar)
        let ranges = periodRanges(weeksPerPeriod: summaryWeeksPerPeriod,
                                  endingAt: endingAt,
                                  calendar: calendar)
        let currentPace = averagePace(summaries,
                                      type: type,
                                      start: ranges.current.start,
                                      end: ranges.current.end)
        let previousPace = averagePace(summaries,
                                       type: type,
                                       start: ranges.previous.start,
                                       end: ranges.previous.end)
        let paceDelta = currentPace.flatMap { current in
            previousPace.map { previous in current - previous }
        }
        let paceTrend: TrendDirection
        if let paceDelta {
            if paceDelta < -paceTrendBandSecPerKm {
                paceTrend = .improving
            } else if paceDelta > paceTrendBandSecPerKm {
                paceTrend = .declining
            } else {
                paceTrend = .steady
            }
        } else {
            paceTrend = .insufficientData
        }

        let distanceTrend: TrendDirection
        if let delta = comparison.distanceDeltaFraction {
            if delta > distanceTrendBandFraction {
                distanceTrend = .improving
            } else if delta < -distanceTrendBandFraction {
                distanceTrend = .declining
            } else {
                distanceTrend = .steady
            }
        } else {
            distanceTrend = .insufficientData
        }

        return InsightSummary(sessionsPerWeek: comparison.sessionsPerWeekCurrent,
                              sessionsPerWeekPrevious: comparison.sessionsPerWeekPrevious,
                              paceTrend: paceTrend,
                              paceDeltaSecPerKm: paceDelta,
                              distanceTrend: distanceTrend,
                              hasEnoughData: comparison.sessions.current > 0)
    }

    private static func periodRanges(weeksPerPeriod: Int, endingAt: Date,
                                     calendar: Calendar)
    -> (current: (start: Date, end: Date), previous: (start: Date, end: Date)) {
        let endWeekStart = mondayStart(for: endingAt, calendar: calendar)
        let currentStart = calendar.date(byAdding: .weekOfYear,
                                         value: -(weeksPerPeriod - 1),
                                         to: endWeekStart)!
        let currentEnd = calendar.date(byAdding: .weekOfYear,
                                       value: 1,
                                       to: endWeekStart)!
        let previousStart = calendar.date(byAdding: .weekOfYear,
                                          value: -weeksPerPeriod,
                                          to: currentStart)!
        return (current: (start: currentStart, end: currentEnd),
                previous: (start: previousStart, end: currentStart))
    }

    private static func totals(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                               start: Date, end: Date)
    -> (distanceMeters: Double, sessions: Int, movingSeconds: Double) {
        summaries
            .filter { $0.type == type && $0.date >= start && $0.date < end }
            .reduce((distanceMeters: 0.0, sessions: 0, movingSeconds: 0.0)) { partial, summary in
                (distanceMeters: partial.distanceMeters + summary.distanceMeters,
                 sessions: partial.sessions + 1,
                 movingSeconds: partial.movingSeconds + summary.movingSeconds)
            }
    }

    private static func averagePace(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                                    start: Date, end: Date) -> Double? {
        let paced = summaries.filter {
            $0.type == type
            && $0.date >= start
            && $0.date < end
            && $0.distanceMeters > 0
            && $0.movingSeconds > 0
        }
        let distanceMeters = paced.reduce(0) { $0 + $1.distanceMeters }
        guard distanceMeters > 0 else { return nil }

        let movingSeconds = paced.reduce(0) { $0 + $1.movingSeconds }
        return movingSeconds / (distanceMeters / 1000.0)
    }

    private static func mondayStart(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day)!
    }

    private struct WeekBucket {
        var distanceMeters = 0.0
        var pacedDistanceMeters = 0.0
        var pacedMovingSeconds = 0.0
        var sessions = 0
    }
}
