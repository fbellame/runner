import Testing
import Foundation
@testable import Runner

struct ActivityStatsTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int = 2026, _ month: Int = 7, _ day: Int = 1,
                      hour: Int = 12) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone,
                                      year: year,
                                      month: month,
                                      day: day,
                                      hour: hour))!
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

    private func record(_ records: [PersonalRecord], _ kind: RecordKind) -> PersonalRecord? {
        records.first { $0.kind == kind }
    }

    @Test func lifetimeTotalsSumMixedTypesAndPerTypeCounts() {
        let summaries = [
            summary(type: .run, distanceMeters: 5_000, movingSeconds: 1_500,
                    points: 50, calories: 220, hasRoute: true),
            summary(type: .walk, distanceMeters: 2_000, movingSeconds: 1_800,
                    points: 20, calories: 90),
            summary(type: .bike, distanceMeters: 12_000, movingSeconds: 2_400,
                    points: 60, calories: 310, hasRoute: true)
        ]

        let totals = ActivityStats.lifetimeTotals(summaries)

        #expect(totals.distanceMeters == 19_000)
        #expect(totals.movingSeconds == 5_700)
        #expect(totals.calories == 620)
        #expect(totals.workouts == 3)
        #expect(totals.perType[.run]?.distanceMeters == 5_000)
        #expect(totals.perType[.run]?.workouts == 1)
        #expect(totals.perType[.walk]?.distanceMeters == 2_000)
        #expect(totals.perType[.walk]?.workouts == 1)
        #expect(totals.perType[.bike]?.distanceMeters == 12_000)
        #expect(totals.perType[.bike]?.workouts == 1)
    }

    @Test func typeStatsFilterInvalidPaceInputsForBestAndAveragePace() {
        let summaries = [
            summary(distanceMeters: 0, movingSeconds: 180),
            summary(distanceMeters: 1_000, movingSeconds: 0),
            summary(distanceMeters: 1_000, movingSeconds: 300, points: 10),
            summary(distanceMeters: 2_000, movingSeconds: 660, points: 20)
        ]

        let stats = ActivityStats.typeStats(summaries, type: .run, calendar: cal)

        #expect(stats.sessions == 4)
        #expect(stats.totalDistanceMeters == 4_000)
        #expect(stats.totalMovingSeconds == 1_140)
        #expect(stats.bestPaceSecPerKm == 300)
        #expect(stats.avgPaceSecPerKm == 320)
    }

    @Test func bestAveragePaceRecordRequiresAtLeastOneKilometer() {
        let shortID = UUID()
        let bestID = UUID()
        let summaries = [
            summary(id: shortID, distanceMeters: 200, movingSeconds: 20),
            summary(distanceMeters: 1_000, movingSeconds: 400),
            summary(id: bestID, distanceMeters: 2_000, movingSeconds: 760)
        ]

        let records = ActivityStats.typeRecords(summaries, type: .run)
        let best = record(records, .bestAveragePace)

        #expect(best?.workoutID == bestID)
        #expect(best?.value == 380)
        #expect(best?.workoutID != shortID)
    }

    @Test func longestRecordIsScopedPerType() {
        let runID = UUID()
        let walkID = UUID()
        let summaries = [
            summary(type: .run, distanceMeters: 1_000, movingSeconds: 300),
            summary(id: walkID, type: .walk, distanceMeters: 4_000, movingSeconds: 2_400),
            summary(id: runID, type: .run, distanceMeters: 3_000, movingSeconds: 1_200)
        ]

        let records = ActivityStats.typeRecords(summaries, type: .run)

        #expect(record(records, .longestDistance)?.workoutID == runID)
        #expect(record(records, .longestDistance)?.value == 3_000)
        #expect(record(ActivityStats.typeRecords(summaries, type: .walk), .longestDistance)?.workoutID == walkID)
    }

    @Test func fastestOneKilometerUsesSingleSplitAcrossWorkouts() {
        let winnerID = UUID()
        let summaries = [
            summary(distanceMeters: 2_000, movingSeconds: 620, splitSeconds: [310, 310]),
            summary(id: winnerID, distanceMeters: 3_000, movingSeconds: 900, splitSeconds: [305, 289, 306]),
            summary(type: .walk, distanceMeters: 1_000, movingSeconds: 200, splitSeconds: [200])
        ]

        let fastest = record(ActivityStats.typeRecords(summaries, type: .run), .fastestOneKilometer)

        #expect(fastest?.workoutID == winnerID)
        #expect(fastest?.value == 289)
    }

    @Test func fastestFiveKilometerRequiresFiveSplitsAndUsesRollingWindow() {
        let fiveSplitID = UUID()
        let sevenSplitID = UUID()
        let short = [summary(distanceMeters: 4_000, movingSeconds: 1_200,
                             splitSeconds: [300, 300, 300, 300])]

        #expect(record(ActivityStats.typeRecords(short, type: .run), .fastestFiveKilometers) == nil)

        let summaries = [
            summary(id: fiveSplitID, distanceMeters: 5_000, movingSeconds: 1_500,
                    splitSeconds: [300, 300, 300, 300, 300]),
            summary(id: sevenSplitID, distanceMeters: 7_000, movingSeconds: 2_450,
                    splitSeconds: [400, 290, 280, 270, 260, 250, 500])
        ]

        let fastest = record(ActivityStats.typeRecords(summaries, type: .run), .fastestFiveKilometers)

        #expect(fastest?.workoutID == sevenSplitID)
        #expect(fastest?.value == 1_350)
        #expect(fastest?.workoutID != fiveSplitID)
    }

    @Test func emptyInputsProduceZerosAndNilRecords() {
        let totals = ActivityStats.lifetimeTotals([])
        let stats = ActivityStats.typeStats([], type: .run, calendar: cal)
        let records = ActivityStats.typeRecords([], type: .run)

        #expect(totals.distanceMeters == 0)
        #expect(totals.movingSeconds == 0)
        #expect(totals.calories == 0)
        #expect(totals.workouts == 0)
        #expect(totals.perType[.run]?.distanceMeters == 0)
        #expect(stats.sessions == 0)
        #expect(stats.totalDistanceMeters == 0)
        #expect(stats.totalMovingSeconds == 0)
        #expect(stats.bestPaceSecPerKm == nil)
        #expect(stats.avgPaceSecPerKm == nil)
        #expect(stats.weeklyDistance.isEmpty)
        #expect(records.isEmpty)
    }

    @Test func weeklyBucketingUsesMondayCalendarWeeksAcrossDST() {
        let summaries = [
            summary(date: date(2026, 3, 8, hour: 1), distanceMeters: 1_000, movingSeconds: 300),
            summary(date: date(2026, 3, 9), distanceMeters: 2_000, movingSeconds: 600)
        ]

        let stats = ActivityStats.typeStats(summaries, type: .run, calendar: cal)

        #expect(stats.weeklyDistance.count == 2)
        #expect(stats.weeklyDistance[0].weekStart == date(2026, 3, 2, hour: 0))
        #expect(stats.weeklyDistance[0].meters == 1_000)
        #expect(stats.weeklyDistance[1].weekStart == date(2026, 3, 9, hour: 0))
        #expect(stats.weeklyDistance[1].meters == 2_000)
    }

    @Test func lifetimeTotalsSumCo2Saved() {
        let summaries = [
            ActivityWorkoutSummary(id: UUID(), type: .bike, date: .now, distanceMeters: 5000,
                                   movingSeconds: 1200, points: 5, calories: 100,
                                   splitSeconds: [], hasRoute: false, co2SavedGrams: 900),
            ActivityWorkoutSummary(id: UUID(), type: .bike, date: .now, distanceMeters: 3000,
                                   movingSeconds: 800, points: 3, calories: 60,
                                   splitSeconds: [], hasRoute: false, co2SavedGrams: 576),
        ]
        let totals = ActivityStats.lifetimeTotals(summaries)
        #expect(abs(totals.co2SavedGrams - 1476) < 0.001)
    }
}
