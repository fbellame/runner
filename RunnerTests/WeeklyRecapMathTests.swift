import Testing
import Foundation
@testable import Runner

struct WeeklyRecapMathTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      hour: Int = 12, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone,
                                      year: year, month: month, day: day,
                                      hour: hour, minute: minute))!
    }

    private func ledger(_ date: Date, points: Int, gold: Bool = false) -> RecapLedgerDay {
        RecapLedgerDay(date: date, totalPoints: points, isGold: gold)
    }

    private func workout(_ date: Date, type: ActivityType = .run,
                         distanceMeters: Double, movingSeconds: Double = 600) -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(id: UUID(),
                               type: type,
                               date: date,
                               distanceMeters: distanceMeters,
                               movingSeconds: movingSeconds,
                               points: 0,
                               calories: 0,
                               splitSeconds: [],
                               hasRoute: false)
    }

    // now = Wednesday 2026-07-08 (week of Mon 2026-07-06).
    private var now: Date { date(2026, 7, 8, hour: 10) }

    @Test func emptyInputProducesZerosAndNoActivity() {
        let recap = WeeklyRecapMath.recap(ledgers: [], workouts: [], now: now, calendar: cal)

        #expect(recap.points == 0)
        #expect(recap.pointsPrevious == 0)
        #expect(recap.pointsDeltaFraction == nil)
        #expect(recap.distanceMeters == 0)
        #expect(recap.sessions == 0)
        #expect(recap.goldDays == 0)
        #expect(recap.bestEffort == nil)
        #expect(recap.hasActivity == false)
    }

    @Test func currentWeekSumsExcludeOtherWeeksAndFuture() {
        let ledgers = [
            ledger(date(2026, 7, 6), points: 100, gold: true),   // Mon, this week
            ledger(date(2026, 7, 8), points: 42),                // Wed (today), this week
            ledger(date(2026, 7, 5), points: 999),               // Sun, last week — excluded from current
            ledger(date(2026, 7, 9), points: 500)                // Thu, future — excluded
        ]
        let workouts = [
            workout(date(2026, 7, 6, hour: 8), distanceMeters: 5_000),
            workout(date(2026, 7, 8, hour: 9), distanceMeters: 3_000),
            workout(date(2026, 7, 5, hour: 8), distanceMeters: 9_000),   // last week — excluded
            workout(date(2026, 7, 8, hour: 20), distanceMeters: 1_000)   // after now (10:00) — excluded
        ]

        let recap = WeeklyRecapMath.recap(ledgers: ledgers, workouts: workouts, now: now, calendar: cal)

        #expect(recap.points == 142)
        #expect(recap.distanceMeters == 8_000)
        #expect(recap.sessions == 2)
        #expect(recap.goldDays == 1)
        #expect(recap.hasActivity == true)
    }

    @Test func mondayIsCurrentWeekAndPrecedingSundayIsPrevious() {
        let ledgers = [
            ledger(date(2026, 7, 6, hour: 0), points: 30),   // Mon 00:00 — current
            ledger(date(2026, 6, 29), points: 70)            // Mon last week — previous window
        ]
        // Preceding Sunday 2026-07-05 belongs to the previous calendar week, but it is
        // NOT in the shifted previous window [2026-06-29, 2026-07-01], so it is excluded.
        let sundayBefore = ledger(date(2026, 7, 5), points: 500)

        let recap = WeeklyRecapMath.recap(ledgers: ledgers + [sundayBefore],
                                          workouts: [], now: now, calendar: cal)

        #expect(recap.points == 30)
        #expect(recap.pointsPrevious == 70)
    }

    @Test func bestEffortIsMaxDistanceThisWeekTieToEarliest() {
        let workouts = [
            workout(date(2026, 7, 8, hour: 9), type: .bike, distanceMeters: 8_000),   // later tie
            workout(date(2026, 7, 6, hour: 8), type: .run, distanceMeters: 8_000),    // earlier tie — wins
            workout(date(2026, 7, 7, hour: 8), type: .walk, distanceMeters: 2_000),
            workout(date(2026, 7, 1, hour: 8), type: .run, distanceMeters: 20_000)    // last week — ignored
        ]

        let recap = WeeklyRecapMath.recap(ledgers: [], workouts: workouts, now: now, calendar: cal)

        #expect(recap.bestEffort == BestEffort(type: .run,
                                            distanceMeters: 8_000,
                                            date: date(2026, 7, 6, hour: 8)))
    }

    @Test func deltaUsesShiftedPreviousWindowAndIsNilWhenPreviousZero() {
        // Current: Mon+Wed this week = 200. Previous shifted window
        // [2026-06-29, 2026-07-01] catches Mon 2026-06-29 = 160.
        let withPrevious = [
            ledger(date(2026, 7, 6), points: 120),
            ledger(date(2026, 7, 8), points: 80),
            ledger(date(2026, 6, 29), points: 160),
            ledger(date(2026, 7, 2), points: 900)   // Thu last week — outside shifted window
        ]
        let recap = WeeklyRecapMath.recap(ledgers: withPrevious, workouts: [], now: now, calendar: cal)
        #expect(recap.points == 200)
        #expect(recap.pointsPrevious == 160)
        #expect(recap.pointsDeltaFraction == 0.25)

        let noPrevious = WeeklyRecapMath.recap(ledgers: [ledger(date(2026, 7, 6), points: 200)],
                                               workouts: [], now: now, calendar: cal)
        #expect(noPrevious.pointsPrevious == 0)
        #expect(noPrevious.pointsDeltaFraction == nil)
    }

    @Test func goldDaysCountCurrentWeekOnly() {
        let ledgers = [
            ledger(date(2026, 7, 6), points: 10, gold: true),
            ledger(date(2026, 7, 7), points: 10, gold: true),
            ledger(date(2026, 7, 8), points: 10, gold: false),
            ledger(date(2026, 6, 30), points: 10, gold: true)   // last week — excluded
        ]
        let recap = WeeklyRecapMath.recap(ledgers: ledgers, workouts: [], now: now, calendar: cal)
        #expect(recap.goldDays == 2)
    }

    @Test func mondayAlignmentHoldsAcrossDSTSpringForward() {
        // DST spring-forward in America/Toronto: Sun 2026-03-08. now = Wed 2026-03-11,
        // week of Mon 2026-03-09.
        let dstNow = date(2026, 3, 11, hour: 10)
        let ledgers = [
            ledger(date(2026, 3, 9), points: 50),    // Mon this week
            ledger(date(2026, 3, 8), points: 999)    // Sun (spanned the DST change) — previous week
        ]
        let recap = WeeklyRecapMath.recap(ledgers: ledgers, workouts: [], now: dstNow, calendar: cal)
        #expect(recap.points == 50)
    }
}
