import Testing
import Foundation
@testable import Runner

struct GoalsMathTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone,
                                      year: year, month: month, day: day, hour: hour))!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, gold: Bool, target: Int = 3) -> GoalLedgerDay {
        GoalLedgerDay(date: date(y, m, d), isGold: gold, weeklyTarget: target)
    }

    // Reference week: Monday 2026-07-06 ... Sunday 2026-07-12.

    @Test func currentWeekCountsGoldDaysAndDots() {
        let days = [day(2026, 7, 6, gold: true),    // Mon gold
                    day(2026, 7, 7, gold: false),   // Tue missed
                    day(2026, 7, 8, gold: true)]    // Wed gold
        let status = GoalsMath.currentWeek(days, currentTarget: 3,
                                           asOf: date(2026, 7, 9), calendar: cal) // Thu
        #expect(status.goldDays == 2)
        #expect(status.target == 3)
        #expect(status.isMet == false)
        #expect(status.dots == [.gold, .missed, .gold, .missed, .future, .future, .future])
    }

    @Test func currentWeekMetUsesLiveTarget() {
        // Snapshots say 5, but the live target is 2 — the current week judges at 2.
        let days = [day(2026, 7, 6, gold: true, target: 5),
                    day(2026, 7, 7, gold: true, target: 5)]
        let status = GoalsMath.currentWeek(days, currentTarget: 2,
                                           asOf: date(2026, 7, 8), calendar: cal)
        #expect(status.isMet == true)
        #expect(status.streak == 1) // current week counts once completed
    }

    @Test func completedWeeksJudgeByLatestSnapshot() {
        // Mid-week target change: early days snapshot 2, the latest day snapshots 3.
        // Only 2 gold days -> the week is NOT completed at target 3.
        let raised = [day(2026, 6, 29, gold: true, target: 2),
                      day(2026, 6, 30, gold: true, target: 2),
                      day(2026, 7, 3, gold: false, target: 3)]
        #expect(GoalsMath.completedWeeks(raised, calendar: cal).isEmpty)

        // Same week but the latest day still says 2 -> completed, on the 2nd gold day.
        let kept = [day(2026, 6, 29, gold: true, target: 2),
                    day(2026, 6, 30, gold: true, target: 2)]
        let weeks = GoalsMath.completedWeeks(kept, calendar: cal)
        #expect(weeks.count == 1)
        #expect(weeks[0].weekStart == cal.startOfDay(for: date(2026, 6, 29)))
        #expect(weeks[0].completedOn == cal.startOfDay(for: date(2026, 6, 30)))
    }

    @Test func streakBuildsAcrossConsecutiveWeeksAndSurvivesUnfinishedCurrentWeek() {
        // Weeks of Jun 22 and Jun 29 completed (target 1); current week (Jul 6) not yet.
        let days = [day(2026, 6, 24, gold: true, target: 1),
                    day(2026, 6, 30, gold: true, target: 1),
                    day(2026, 7, 6, gold: false, target: 1)]
        let status = GoalsMath.currentWeek(days, currentTarget: 1,
                                           asOf: date(2026, 7, 7), calendar: cal)
        // Unfinished current week does not break the streak, and does not extend it.
        #expect(status.streak == 2)
    }

    @Test func emptyWeekBreaksStreak() {
        // Week of Jun 22 completed, week of Jun 29 has NO ledger days, current week completed.
        let days = [day(2026, 6, 24, gold: true, target: 1),
                    day(2026, 7, 6, gold: true, target: 1)]
        let status = GoalsMath.currentWeek(days, currentTarget: 1,
                                           asOf: date(2026, 7, 7), calendar: cal)
        #expect(status.streak == 1) // only the current week
    }

    @Test func completedWeeksSortedByWeekStart() {
        let days = [day(2026, 7, 6, gold: true, target: 1),
                    day(2026, 6, 22, gold: true, target: 1)]
        let weeks = GoalsMath.completedWeeks(days, calendar: cal)
        #expect(weeks.map(\.weekStart) == [cal.startOfDay(for: date(2026, 6, 22)),
                                           cal.startOfDay(for: date(2026, 7, 6))])
    }
}
