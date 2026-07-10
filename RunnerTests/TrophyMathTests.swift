import Testing
import Foundation
@testable import Runner

struct TrophyMathTests {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
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

    private func summary(id: UUID = UUID(), type: ActivityType = .run, date: Date? = nil,
                         distanceMeters: Double, movingSeconds: Double = 1_800,
                         splitSeconds: [Double] = []) -> ActivityWorkoutSummary {
        ActivityWorkoutSummary(id: id, type: type, date: date ?? self.date(),
                               distanceMeters: distanceMeters, movingSeconds: movingSeconds,
                               points: 0, calories: 0, splitSeconds: splitSeconds, hasRoute: false)
    }

    private func badge(_ badges: [Badge], _ id: String) -> Badge? {
        badges.first { $0.id == id }
    }

    private func badgeIDs(in achievements: [Achievement]) -> [String] {
        achievements.compactMap {
            guard case .newBadge(let badge) = $0.kind else { return nil }
            return badge.id
        }
    }

    private func recordAchievements(in achievements: [Achievement]) -> [PersonalRecord] {
        achievements.compactMap {
            guard case .newRecord(let record) = $0.kind else { return nil }
            return record
        }
    }

    @Test func emptyHistoryProducesAllLockedBadges() {
        let badges = TrophyMath.allBadges([])

        #expect(badges.count == 44)
        #expect(badges.allSatisfy { !$0.earned && $0.earnedAt == nil })
        #expect(badges.allSatisfy { $0.progress == 0 })
    }

    @Test func runDistanceUsesTypeLadderAndOnlyNextBadgeHasProgress() {
        let badges = TrophyMath.allBadges([summary(distanceMeters: 120_000)])

        for threshold in [10, 25, 50, 100] {
            #expect(badge(badges, "distance.run.\(threshold)")?.earned == true)
        }
        #expect(badge(badges, "distance.run.250")?.progress == 120.0 / 250.0)
        #expect(badge(badges, "distance.run.500")?.progress == 0)
        #expect(badge(badges, "distance.run.1000")?.progress == 0)
    }

    @Test func bikeUsesBikeSpecificDistanceLadder() {
        let badges = TrophyMath.allBadges([summary(type: .bike, distanceMeters: 30_000)])

        #expect(badge(badges, "distance.bike.25")?.earned == true)
        #expect(badge(badges, "distance.bike.50")?.progress == 0.6)
        #expect(badge(badges, "distance.bike.10") == nil)
    }

    @Test func earnedDatesReplayChronologicallyRegardlessOfInputOrder() {
        let jan1 = date(2026, 1, 1)
        let jan5 = date(2026, 1, 5)
        let feb1 = date(2026, 2, 1)
        let summaries = [
            summary(date: jan1, distanceMeters: 6_000),
            summary(date: jan5, distanceMeters: 5_000),
            summary(date: feb1, distanceMeters: 20_000)
        ]

        let badges = TrophyMath.allBadges(summaries)
        let shuffled = TrophyMath.allBadges([summaries[2], summaries[0], summaries[1]])

        #expect(badge(badges, "distance.run.10")?.earnedAt == jan5)
        #expect(badge(badges, "distance.run.25")?.earnedAt == feb1)
        #expect(badges == shuffled)
    }

    @Test func countLaddersRecordTheWorkoutThatCrossedTheThreshold() {
        let summaries = (1...10).map { day in
            summary(type: .walk, date: date(2026, 1, day), distanceMeters: 1_000)
        }
        let badges = TrophyMath.allBadges(summaries)

        #expect(badge(badges, "count.walk.10")?.earned == true)
        #expect(badge(badges, "count.walk.10")?.earnedAt == date(2026, 1, 10))
        #expect(badge(badges, "count.global.10")?.earned == true)
    }

    @Test func badgeIDsUseStableKindScopeAndThresholdFormat() {
        let ids = Set(TrophyMath.allBadges([]).map(\.id))

        #expect(ids.contains("distance.bike.250"))
        #expect(ids.contains("count.global.100"))
    }

    @Test func achievementsPutNewRecordBeforeNewBadges() {
        let history = [summary(date: date(2026, 1, 1), distanceMeters: 9_000,
                               movingSeconds: 2_700)]
        let candidate = summary(date: date(2026, 1, 2), distanceMeters: 20_000,
                                movingSeconds: 6_000)

        let achievements = TrophyMath.achievements(history: history, candidate: candidate)

        #expect(recordAchievements(in: achievements).first?.kind == .longestDistance)
        #expect(achievements.first?.id == "record.run.longestDistance")
        #expect(badgeIDs(in: achievements).contains("distance.run.25"))
    }

    @Test func achievementsReturnNewRecordOnlyWhenNoBadgeWasCrossed() {
        let history = [summary(distanceMeters: 30_000, movingSeconds: 6_000)]
        let candidate = summary(distanceMeters: 4_000, movingSeconds: 760)

        let achievements = TrophyMath.achievements(history: history, candidate: candidate)

        #expect(recordAchievements(in: achievements).map(\.kind) == [.bestAveragePace])
        #expect(badgeIDs(in: achievements).isEmpty)
    }

    @Test func achievementsReturnBadgesOnlyForFirstWorkoutOfAType() {
        let candidate = summary(type: .bike, distanceMeters: 25_000)

        let achievements = TrophyMath.achievements(history: [], candidate: candidate)

        #expect(recordAchievements(in: achievements).isEmpty)
        #expect(!badgeIDs(in: achievements).isEmpty)
    }

    @Test func firstEverBikeRideSuppressesRecordsEvenWhenItEarnsABadge() {
        let candidate = summary(type: .bike, distanceMeters: 12_000)

        let achievements = TrophyMath.achievements(history: [], candidate: candidate)

        #expect(recordAchievements(in: achievements).isEmpty)
        #expect(badgeIDs(in: achievements) == ["distance.global.10"])
    }

    @Test func achievementsReturnNothingWhenCandidateBeatsNoRecordOrBadge() {
        let history = [summary(distanceMeters: 30_000, movingSeconds: 6_000)]
        let candidate = summary(distanceMeters: 1_000, movingSeconds: 500)

        #expect(TrophyMath.achievements(history: history, candidate: candidate).isEmpty)
    }

    @Test func achievementsIncludeEveryNewThresholdCrossedByOneWorkout() {
        let history = [summary(date: date(2026, 1, 1), distanceMeters: 9_000)]
        let candidate = summary(date: date(2026, 1, 2), distanceMeters: 20_000)

        let achievements = TrophyMath.achievements(history: history, candidate: candidate)
        let runDistanceIDs = badgeIDs(in: achievements).filter { $0.hasPrefix("distance.run") }

        #expect(runDistanceIDs == ["distance.run.10", "distance.run.25"])
    }

    @Test func nextMilestoneChoosesHighestProgressAcrossOpenLadders() {
        let badges = TrophyMath.nextMilestone([
            summary(type: .bike, distanceMeters: 960_000),
            summary(type: .run, distanceMeters: 40_000)
        ])

        #expect(badges?.id == "distance.bike.1000")
    }

    @Test func nextMilestoneBreaksProgressTiesWithLargerThreshold() {
        let summaries = [
            summary(type: .run, distanceMeters: 500_000),
            summary(type: .bike, distanceMeters: 1_250_000)
        ]

        #expect(TrophyMath.nextMilestone(summaries)?.id == "distance.bike.2500")
    }

    @Test func nextMilestoneIsNilForEmptyAndCompleteLadders() {
        #expect(TrophyMath.nextMilestone([]) == nil)

        let complete = ActivityType.allCases.flatMap { type in
            (0..<100).map { offset in
                summary(type: type, date: date(2026, 1, 1 + offset),
                        distanceMeters: type == .bike ? 25_000 : 10_000)
            }
        }
        #expect(TrophyMath.nextMilestone(complete) == nil)
    }
}
