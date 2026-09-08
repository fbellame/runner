import Testing
import Foundation
@testable import Runner

struct InsightsMathTests {
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
                         points: Int = 0,
                         calories: Double = 0,
                         splitSeconds: [Double] = [],
                         hasRoute: Bool = false) -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(id: id,
                               type: type,
                               date: date ?? self.date(),
                               distanceMeters: distanceMeters,
                               movingSeconds: movingSeconds,
                               points: points,
                               calories: calories,
                               splitSeconds: splitSeconds,
                               hasRoute: hasRoute)
    }

    @Test func weeklySeriesReturnsDenseOldestToNewestWeeksEndingAtPinnedWeek() {
        let endingAt = date(2026, 7, 8)
        let summaries = [
            summary(date: date(2026, 6, 16), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 7, 7), distanceMeters: 2_000, movingSeconds: 620)
        ]

        let series = InsightsMath.weeklySeries(summaries,
                                               type: .run,
                                               weeks: 4,
                                               endingAt: endingAt,
                                               calendar: cal)

        #expect(series.count == 4)
        #expect(series.map(\.weekStart) == [
            date(2026, 6, 15, hour: 0),
            date(2026, 6, 22, hour: 0),
            date(2026, 6, 29, hour: 0),
            date(2026, 7, 6, hour: 0)
        ])
        #expect(series[0].distanceMeters == 1_000)
        #expect(series[0].sessions == 1)
        #expect(series[1].distanceMeters == 0)
        #expect(series[1].sessions == 0)
        #expect(series[1].avgPaceSecPerKm == nil)
        #expect(series[3].distanceMeters == 2_000)
        #expect(series[3].sessions == 1)
    }

    @Test func weeklySeriesComputesKmWeightedPaceAndFiltersTypeAndInvalidPaceInputs() {
        let endingAt = date(2026, 7, 8)
        let summaries = [
            summary(date: date(2026, 7, 7), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 7, 8), distanceMeters: 2_000, movingSeconds: 660),
            summary(date: date(2026, 7, 8), distanceMeters: 0, movingSeconds: 120),
            summary(date: date(2026, 7, 8), distanceMeters: 500, movingSeconds: 0),
            summary(type: .walk, date: date(2026, 7, 8), distanceMeters: 9_000, movingSeconds: 900)
        ]

        let series = InsightsMath.weeklySeries(summaries,
                                               type: .run,
                                               weeks: 1,
                                               endingAt: endingAt,
                                               calendar: cal)

        #expect(series.count == 1)
        #expect(series[0].distanceMeters == 3_500)
        #expect(series[0].sessions == 4)
        #expect(series[0].avgPaceSecPerKm == 320)
    }

    @Test func periodComparisonSplitsCurrentAndPreviousAtMondayBoundary() {
        let endingAt = date(2026, 7, 8)
        let summaries = [
            summary(date: date(2026, 5, 17), distanceMeters: 9_000, movingSeconds: 900),
            summary(date: date(2026, 5, 18, hour: 0), distanceMeters: 500, movingSeconds: 150),
            summary(date: date(2026, 6, 14), distanceMeters: 1_500, movingSeconds: 450),
            summary(date: date(2026, 6, 15, hour: 0), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 7, 7), distanceMeters: 2_000, movingSeconds: 600),
            summary(type: .bike, date: date(2026, 7, 7), distanceMeters: 20_000, movingSeconds: 2_000)
        ]

        let comparison = InsightsMath.periodComparison(summaries,
                                                       type: .run,
                                                       weeksPerPeriod: 4,
                                                       endingAt: endingAt,
                                                       calendar: cal)

        #expect(comparison.distanceMeters.current == 3_000)
        #expect(comparison.distanceMeters.previous == 2_000)
        #expect(comparison.sessions.current == 2)
        #expect(comparison.sessions.previous == 2)
        #expect(comparison.movingSeconds.current == 900)
        #expect(comparison.movingSeconds.previous == 600)
        #expect(comparison.distanceDeltaFraction == 0.5)
        #expect(comparison.movingSecondsDeltaFraction == 0.5)
        #expect(comparison.sessionsPerWeekCurrent == 0.5)
        #expect(comparison.sessionsPerWeekPrevious == 0.5)
        #expect(comparison.sessionsPerWeekDelta == 0)
    }

    @Test func periodComparisonReturnsNilDeltasWhenPreviousValueIsZero() {
        let comparison = InsightsMath.periodComparison([
            summary(date: date(2026, 7, 7), distanceMeters: 2_000, movingSeconds: 600)
        ],
        type: .run,
        weeksPerPeriod: 4,
        endingAt: date(2026, 7, 8),
        calendar: cal)

        #expect(comparison.distanceMeters.current == 2_000)
        #expect(comparison.distanceMeters.previous == 0)
        #expect(comparison.distanceDeltaFraction == nil)
        #expect(comparison.movingSecondsDeltaFraction == nil)
        #expect(comparison.sessionsPerWeekCurrent == 0.25)
        #expect(comparison.sessionsPerWeekPrevious == 0)
        #expect(comparison.sessionsPerWeekDelta == 0.25)
    }

    @Test func summaryComputesSessionFrequencyAndImprovingPaceAndDistance() {
        let result = InsightsMath.summary([
            summary(date: date(2026, 5, 19), distanceMeters: 4_000, movingSeconds: 1_200),
            summary(date: date(2026, 6, 17), distanceMeters: 5_000, movingSeconds: 1_480),
            summary(date: date(2026, 6, 24), distanceMeters: 3_000, movingSeconds: 888),
            summary(date: date(2026, 7, 7), distanceMeters: 1_000, movingSeconds: 296)
        ],
        type: .run,
        endingAt: date(2026, 7, 8),
        calendar: cal)

        #expect(result.sessionsPerWeek == 0.75)
        #expect(result.sessionsPerWeekPrevious == 0.25)
        #expect(result.paceTrend == .improving)
        #expect(result.paceDeltaSecPerKm == -4)
        #expect(result.hasEnoughData == true)
    }

    @Test func summaryMarksPaceDeclining() {
        let result = InsightsMath.summary([
            summary(date: date(2026, 5, 19), distanceMeters: 10_000, movingSeconds: 3_000),
            summary(date: date(2026, 6, 17), distanceMeters: 8_000, movingSeconds: 2_432)
        ],
        type: .run,
        endingAt: date(2026, 7, 8),
        calendar: cal)

        #expect(result.paceTrend == .declining)
        #expect(result.paceDeltaSecPerKm == 4)
        #expect(result.hasEnoughData == true)
    }

    @Test func summaryMarksPaceAndDistanceSteadyWithinThresholds() {
        let result = InsightsMath.summary([
            summary(date: date(2026, 5, 19), distanceMeters: 10_000, movingSeconds: 3_000),
            summary(date: date(2026, 6, 17), distanceMeters: 11_000, movingSeconds: 3_322)
        ],
        type: .run,
        endingAt: date(2026, 7, 8),
        calendar: cal)

        #expect(result.paceTrend == .steady)
        #expect(result.paceDeltaSecPerKm == 2)
        #expect(result.hasEnoughData == true)
    }

    @Test func summaryUsesStrictTrendThresholdsAtThreeSecondsAndTenPercent() {
        let result = InsightsMath.summary([
            summary(date: date(2026, 5, 19), distanceMeters: 10_000, movingSeconds: 3_000),
            summary(date: date(2026, 6, 17), distanceMeters: 11_000, movingSeconds: 3_267)
        ],
        type: .run,
        endingAt: date(2026, 7, 8),
        calendar: cal)

        #expect(result.paceTrend == .steady)
        #expect(result.paceDeltaSecPerKm == -3)
    }

    @Test func summaryHasInsufficientPaceDataWhenEitherPeriodHasNoPacedSession() {
        let missingPreviousPace = InsightsMath.summary([
            summary(date: date(2026, 5, 19), distanceMeters: 0, movingSeconds: 600),
            summary(date: date(2026, 6, 17), distanceMeters: 2_000, movingSeconds: 600)
        ],
        type: .run,
        endingAt: date(2026, 7, 8),
        calendar: cal)

        #expect(missingPreviousPace.paceTrend == .insufficientData)
        #expect(missingPreviousPace.paceDeltaSecPerKm == nil)
        #expect(missingPreviousPace.hasEnoughData == true)
    }

    @Test func emptyInputProducesZerosInsufficientDataAndNoCrash() {
        let weekly = InsightsMath.weeklySeries([],
                                               type: .run,
                                               weeks: 3,
                                               endingAt: date(2026, 7, 8),
                                               calendar: cal)
        let comparison = InsightsMath.periodComparison([],
                                                       type: .run,
                                                       weeksPerPeriod: 4,
                                                       endingAt: date(2026, 7, 8),
                                                       calendar: cal)
        let result = InsightsMath.summary([],
                                          type: .run,
                                          endingAt: date(2026, 7, 8),
                                          calendar: cal)

        #expect(weekly.count == 3)
        #expect(weekly.allSatisfy { $0.distanceMeters == 0 && $0.sessions == 0 && $0.avgPaceSecPerKm == nil })
        #expect(comparison.distanceMeters.current == 0)
        #expect(comparison.distanceMeters.previous == 0)
        #expect(comparison.sessions.current == 0)
        #expect(comparison.sessions.previous == 0)
        #expect(result.sessionsPerWeek == 0)
        #expect(result.sessionsPerWeekPrevious == 0)
        #expect(result.paceTrend == .insufficientData)
        #expect(result.paceDeltaSecPerKm == nil)
        #expect(result.hasEnoughData == false)
    }

    @Test func weeklySeriesKeepsMondayStartsAcrossDSTBoundary() {
        let series = InsightsMath.weeklySeries([
            summary(date: date(2026, 3, 8, hour: 1), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 3, 9), distanceMeters: 2_000, movingSeconds: 600)
        ],
        type: .run,
        weeks: 3,
        endingAt: date(2026, 3, 10),
        calendar: cal)

        #expect(series.count == 3)
        #expect(series.map(\.weekStart) == [
            date(2026, 2, 23, hour: 0),
            date(2026, 3, 2, hour: 0),
            date(2026, 3, 9, hour: 0)
        ])
        #expect(series[1].distanceMeters == 1_000)
        #expect(series[2].distanceMeters == 2_000)
    }
}
