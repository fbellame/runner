import Testing
import Foundation
@testable import Runner

struct HubMathTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int = 2026, _ month: Int = 7, _ day: Int = 1,
                      hour: Int = 12, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone,
                                      year: year,
                                      month: month,
                                      day: day,
                                      hour: hour,
                                      minute: minute))!
    }

    private func summary(id: UUID = UUID(),
                         type: ActivityType = .run,
                         date: Date? = nil,
                         distanceMeters: Double,
                         movingSeconds: Double,
                         co2SavedGrams: Double = 0) -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(id: id,
                               type: type,
                               date: date ?? self.date(),
                               distanceMeters: distanceMeters,
                               movingSeconds: movingSeconds,
                               points: 0,
                               calories: 0,
                               splitSeconds: [],
                               hasRoute: false,
                               co2SavedGrams: co2SavedGrams)
    }

    // MARK: - yearInReview

    @Test func yearInReviewComparesSameDateRangeAcrossYears() {
        let asOf = date(2026, 7, 8)
        let summaries = [
            // current year, in range
            summary(date: date(2026, 1, 1, hour: 0), distanceMeters: 4_000, movingSeconds: 1_200),
            summary(date: date(2026, 7, 7), distanceMeters: 6_000, movingSeconds: 1_800),
            // current year, after asOf: excluded
            summary(date: date(2026, 7, 8, hour: 13), distanceMeters: 9_000, movingSeconds: 900),
            // previous year, before the same-date cutoff: included
            summary(date: date(2025, 1, 5), distanceMeters: 3_000, movingSeconds: 1_000),
            summary(date: date(2025, 7, 8, hour: 11), distanceMeters: 2_000, movingSeconds: 500),
            // previous year, after the same-date cutoff: excluded
            summary(date: date(2025, 7, 8, hour: 13), distanceMeters: 8_000, movingSeconds: 800),
            summary(date: date(2025, 12, 1), distanceMeters: 7_000, movingSeconds: 700),
            // other type: excluded
            summary(type: .bike, date: date(2026, 3, 1), distanceMeters: 20_000, movingSeconds: 2_000)
        ]

        let review = HubMath.yearInReview(summaries, type: .run, asOf: asOf, calendar: cal)

        #expect(review.year == 2026)
        #expect(review.distanceMeters.current == 10_000)
        #expect(review.distanceMeters.previous == 5_000)
        #expect(review.sessions.current == 2)
        #expect(review.sessions.previous == 2)
        #expect(review.movingSeconds.current == 3_000)
        #expect(review.movingSeconds.previous == 1_500)
        #expect(review.isFirstTrackedYear == false)
        #expect(review.distanceDeltaFraction == 1.0)
    }

    @Test func yearInReviewSumsCo2AndTreatsTypeWithoutHistoryAsFirstYear() {
        let asOf = date(2026, 7, 8)
        let summaries = [
            summary(type: .bike, date: date(2026, 4, 1), distanceMeters: 10_000,
                    movingSeconds: 2_400, co2SavedGrams: 1_920),
            summary(type: .bike, date: date(2026, 5, 1), distanceMeters: 5_000,
                    movingSeconds: 1_200, co2SavedGrams: 960),
            // a run last year must not stop the bike hub from being "first year"
            summary(type: .run, date: date(2025, 6, 1), distanceMeters: 5_000, movingSeconds: 1_500)
        ]

        let review = HubMath.yearInReview(summaries, type: .bike, asOf: asOf, calendar: cal)

        #expect(review.co2SavedGrams.current == 2_880)
        #expect(review.co2SavedGrams.previous == 0)
        #expect(review.isFirstTrackedYear == true)
        #expect(review.distanceDeltaFraction == nil)
    }

    @Test func yearInReviewHandlesLeapDayAsOf() {
        let asOf = date(2028, 2, 29)
        let summaries = [
            summary(date: date(2028, 2, 10), distanceMeters: 5_000, movingSeconds: 1_500),
            // previous year has no Feb 29; cutoff maps to Feb 28 12:00
            summary(date: date(2027, 2, 28, hour: 10), distanceMeters: 3_000, movingSeconds: 900),
            summary(date: date(2027, 3, 1), distanceMeters: 4_000, movingSeconds: 1_200)
        ]

        let review = HubMath.yearInReview(summaries, type: .run, asOf: asOf, calendar: cal)

        #expect(review.distanceMeters.current == 5_000)
        #expect(review.distanceMeters.previous == 3_000)
    }

    // MARK: - monthlySeries

    @Test func monthlySeriesReturnsDenseOldestToNewestMonthsWithZeroGaps() {
        let series = HubMath.monthlySeries([
            summary(date: date(2026, 5, 31, hour: 23), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 6, 1, hour: 0), distanceMeters: 2_000, movingSeconds: 660),
            summary(type: .walk, date: date(2026, 6, 15), distanceMeters: 9_000, movingSeconds: 900)
        ],
        type: .run,
        months: 3,
        endingAt: date(2026, 7, 8),
        calendar: cal)

        #expect(series.count == 3)
        #expect(series.map(\.monthStart) == [
            date(2026, 5, 1, hour: 0),
            date(2026, 6, 1, hour: 0),
            date(2026, 7, 1, hour: 0)
        ])
        #expect(series[0].distanceMeters == 1_000)
        #expect(series[0].sessions == 1)
        #expect(series[0].avgPaceSecPerKm == 300)
        #expect(series[1].distanceMeters == 2_000)
        #expect(series[1].avgPaceSecPerKm == 330)
        #expect(series[2].distanceMeters == 0)
        #expect(series[2].sessions == 0)
        #expect(series[2].avgPaceSecPerKm == nil)
    }

    @Test func monthlySeriesSpansYearBoundary() {
        let series = HubMath.monthlySeries([
            summary(date: date(2025, 11, 20), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 1, 10), distanceMeters: 2_000, movingSeconds: 600)
        ],
        type: .run,
        months: 3,
        endingAt: date(2026, 1, 15),
        calendar: cal)

        #expect(series.map(\.monthStart) == [
            date(2025, 11, 1, hour: 0),
            date(2025, 12, 1, hour: 0),
            date(2026, 1, 1, hour: 0)
        ])
        #expect(series[0].distanceMeters == 1_000)
        #expect(series[1].distanceMeters == 0)
        #expect(series[2].distanceMeters == 2_000)
    }

    // MARK: - yearMonthlyComparison

    @Test func yearMonthlyComparisonAlignsMonthsByIndexAcrossYears() {
        let points = HubMath.yearMonthlyComparison([
            summary(date: date(2026, 3, 10), distanceMeters: 5_000, movingSeconds: 1_500),
            summary(date: date(2025, 3, 20), distanceMeters: 3_000, movingSeconds: 900),
            summary(date: date(2025, 11, 5), distanceMeters: 2_000, movingSeconds: 600),
            summary(type: .walk, date: date(2026, 3, 12), distanceMeters: 4_000, movingSeconds: 2_400)
        ],
        type: .run,
        year: 2026,
        calendar: cal)

        #expect(points.count == 12)
        #expect(points.map(\.monthIndex) == Array(1...12))
        #expect(points[2].currentMeters == 5_000)
        #expect(points[2].previousMeters == 3_000)
        #expect(points[10].currentMeters == 0)
        #expect(points[10].previousMeters == 2_000)
        #expect(points[0].currentMeters == 0)
        #expect(points[0].previousMeters == 0)
    }

    // MARK: - consistency

    @Test func consistencyCountsStreaksAndDaysSinceLast() {
        let asOf = date(2026, 7, 8) // Wednesday; current week starts Jul 6
        let stats = HubMath.consistency([
            // lone active week (Apr 27)
            summary(date: date(2026, 5, 1), distanceMeters: 1_000, movingSeconds: 300),
            // three consecutive active weeks: Jun 15, Jun 22, Jun 29
            summary(date: date(2026, 6, 15), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 6, 23), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 6, 29), distanceMeters: 1_000, movingSeconds: 300)
        ],
        type: .run,
        asOf: asOf,
        calendar: cal)

        #expect(stats.longestWeekStreak == 3)
        // current week inactive → grace: streak counted from last week
        #expect(stats.currentWeekStreak == 3)
        #expect(stats.daysSinceLast == 9)
    }

    @Test func consistencyCountsActiveCurrentWeekAndBreaksAfterGap() {
        let asOf = date(2026, 7, 8)
        let active = HubMath.consistency([
            summary(date: date(2026, 6, 29), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 7, 7), distanceMeters: 1_000, movingSeconds: 300)
        ],
        type: .run,
        asOf: asOf,
        calendar: cal)

        #expect(active.longestWeekStreak == 2)
        #expect(active.currentWeekStreak == 2)
        #expect(active.daysSinceLast == 1)

        let lapsed = HubMath.consistency([
            summary(date: date(2026, 6, 15), distanceMeters: 1_000, movingSeconds: 300)
        ],
        type: .run,
        asOf: asOf,
        calendar: cal)

        // last active week is neither the current nor the previous week
        #expect(lapsed.currentWeekStreak == 0)
        #expect(lapsed.longestWeekStreak == 1)
        #expect(lapsed.daysSinceLast == 23)
    }

    @Test func consistencyReturnsNilDaysSinceLastWhenTypeNeverHappened() {
        let stats = HubMath.consistency([
            summary(type: .bike, date: date(2026, 7, 1), distanceMeters: 5_000, movingSeconds: 1_200)
        ],
        type: .run,
        asOf: date(2026, 7, 8),
        calendar: cal)

        #expect(stats.daysSinceLast == nil)
        #expect(stats.longestWeekStreak == 0)
        #expect(stats.currentWeekStreak == 0)
    }

    // MARK: - monthsSpanningAll

    @Test func monthsSpanningAllSpansEarliestWorkoutAndClampsToTwelve() {
        let endingAt = date(2026, 7, 8)

        let multiYear = HubMath.monthsSpanningAll([
            summary(date: date(2024, 11, 15), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 7, 1), distanceMeters: 1_000, movingSeconds: 300)
        ],
        endingAt: endingAt,
        calendar: cal)
        #expect(multiYear == 21) // 2024-11 through 2026-07 inclusive

        let recentOnly = HubMath.monthsSpanningAll([
            summary(date: date(2026, 6, 20), distanceMeters: 1_000, movingSeconds: 300)
        ],
        endingAt: endingAt,
        calendar: cal)
        #expect(recentOnly == 12)

        #expect(HubMath.monthsSpanningAll([], endingAt: endingAt, calendar: cal) == 12)
    }
}
