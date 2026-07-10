import Testing
import Foundation
@testable import Runner

struct WrappedMathTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      hour: Int = 12, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(timeZone: cal.timeZone,
                                      year: year, month: month, day: day,
                                      hour: hour, minute: minute))!
    }

    private func workout(id: UUID = UUID(),
                         type: ActivityType = .run,
                         date: Date,
                         distanceMeters: Double = 1_000,
                         movingSeconds: Double = 600,
                         calories: Double = 0,
                         co2SavedGrams: Double = 0,
                         splitSeconds: [Double] = []) -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(id: id,
                               type: type,
                               date: date,
                               distanceMeters: distanceMeters,
                               movingSeconds: movingSeconds,
                               points: 0,
                               calories: calories,
                               splitSeconds: splitSeconds,
                               hasRoute: false,
                               co2SavedGrams: co2SavedGrams)
    }

    private func wrapped(_ summaries: [ActivityWorkoutSummary],
                         _ year: Int = 2026, _ month: Int = 1) -> MonthWrapped {
        WrappedMath.monthWrapped(summaries,
                                 month: WrappedMonth(year: year, month: month),
                                 calendar: cal)!
    }

    @Test func bucketsMonthsAcrossYearBoundaryAndCalculatesDelta() {
        let december = workout(date: date(2025, 12, 31, hour: 23), distanceMeters: 4_000)
        let january = workout(date: date(2026, 1, 1, hour: 0), distanceMeters: 6_000,
                               movingSeconds: 1_800)
        let deck = wrapped([december, january])

        guard case let .totals(totals) = deck.cards[1] else {
            Issue.record("Expected totals card")
            return
        }
        #expect(totals.distanceMeters == 6_000)
        #expect(totals.workoutCount == 1)
        #expect(totals.movingSeconds == 1_800)
        #expect(totals.distanceDeltaFraction == 0.5)
    }

    @Test func omitsDeltaWhenPreviousMonthIsEmpty() {
        let deck = wrapped([workout(date: date(2026, 1, 12), distanceMeters: 3_000)])

        guard case let .totals(totals) = deck.cards[1] else {
            Issue.record("Expected totals card")
            return
        }
        #expect(totals.distanceDeltaFraction == nil)
    }

    @Test func derivesBadgesAndPersonalRecordsFromBeforeAfterDiffs() {
        let previous = workout(date: date(2025, 12, 20), distanceMeters: 1_000,
                               movingSeconds: 700)
        let record = workout(date: date(2026, 1, 8), distanceMeters: 2_000,
                             movingSeconds: 1_000)
        let badgeWorkouts = (0..<10).map { offset in
            workout(type: .walk, date: date(2026, 1, 10 + offset), distanceMeters: 1_000)
        }
        let deck = wrapped([previous, record] + badgeWorkouts)

        guard case let .highlights(_, records) = deck.cards[2] else {
            Issue.record("Expected highlights card")
            return
        }
        let hasRunDistanceRecord = records.contains { pr in
            let matchesKind: Bool = pr.record.kind == .longestDistance
            let matchesWorkout: Bool = pr.record.workoutID == record.id
            return pr.type == .run && matchesKind && matchesWorkout
        }
        #expect(hasRunDistanceRecord)

        guard let badgeCard = deck.cards.first(where: {
            if case .badges = $0 { return true }
            return false
        }), case let .badges(badges) = badgeCard else {
            Issue.record("Expected badges card")
            return
        }
        #expect(badges.contains { $0.id == "count.global.10" })
        #expect(badges.contains { $0.id == "count.walk.10" })
    }

    @Test func clipsStreakToMonthEdgesAndMapsEveryCalendarDayToHeatStrip() {
        let deck = wrapped([
            workout(date: date(2025, 12, 31)),
            workout(date: date(2026, 1, 1)),
            workout(date: date(2026, 1, 2)),
            workout(date: date(2026, 1, 2, hour: 18)),
            workout(date: date(2026, 1, 4)),
            workout(date: date(2026, 2, 1))
        ])

        guard let consistencyCard = deck.cards.first(where: {
            if case .consistency = $0 { return true }
            return false
        }), case let .consistency(consistency) = consistencyCard else {
            Issue.record("Expected consistency card")
            return
        }
        #expect(consistency.activeDays == 3)
        #expect(consistency.bestStreak == 2)
        #expect(consistency.heatStrip.count == 31)
        #expect(consistency.heatStrip[0].date == date(2026, 1, 1, hour: 0))
        #expect(consistency.heatStrip[0].workoutCount == 1)
        #expect(consistency.heatStrip[1].workoutCount == 2)
        #expect(consistency.heatStrip[2].workoutCount == 0)
        #expect(consistency.heatStrip[30].date == date(2026, 1, 31, hour: 0))
    }

    @Test func availableMonthsAreNewestFirstAndExcludeCurrentAndEmptyMonths() {
        let summaries = [
            workout(date: date(2025, 12, 10)),
            workout(date: date(2026, 1, 10)),
            workout(date: date(2026, 3, 1))
        ]

        let months = WrappedMath.availableMonths(summaries,
                                                  asOf: date(2026, 3, 14),
                                                  calendar: cal)
        #expect(months == [WrappedMonth(year: 2026, month: 1),
                           WrappedMonth(year: 2025, month: 12)])
    }

    @Test func omitsEmptyBadgesAndImpactCardsAndKeepsImpactWhenOnlyCaloriesExist() {
        let noImpact = wrapped([workout(date: date(2026, 1, 3))])
        #expect(!noImpact.cards.contains {
            if case .badges = $0 { return true }
            return false
        })
        #expect(!noImpact.cards.contains {
            if case .impact = $0 { return true }
            return false
        })

        let caloriesOnly = wrapped([workout(date: date(2026, 1, 3), calories: 400)])
        guard let impactCard = caloriesOnly.cards.first(where: {
            if case .impact = $0 { return true }
            return false
        }), case let .impact(impact) = impactCard else {
            Issue.record("Expected impact card")
            return
        }
        #expect(impact.calories == 400)
        #expect(impact.co2SavedGrams == 0)
        #expect(impact.carKilometers == 0)
    }
}
