import Foundation

enum BadgeKind: String, Sendable {
    case distance
    case count
    case weeklyGoal
    case weeklyStreak
}

enum BadgeScope: Hashable, Sendable {
    case global
    case perType(ActivityType)

    var key: String {
        switch self {
        case .global: "global"
        case .perType(let type): type.rawValue
        }
    }
}

struct Badge: Identifiable, Equatable, Sendable {
    let id: String
    let kind: BadgeKind
    let scope: BadgeScope
    let threshold: Double
    let earned: Bool
    let progress: Double
    let earnedAt: Date?
}

struct Achievement: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case newRecord(PersonalRecord)
        case newBadge(Badge)
    }

    let kind: Kind
    private let recordType: ActivityType?

    init(kind: Kind, recordType: ActivityType? = nil) {
        self.kind = kind
        self.recordType = recordType
    }

    var id: String {
        switch kind {
        case .newRecord(let record): "record.\(recordType?.rawValue ?? "unknown").\(record.kind.idKey)"
        case .newBadge(let badge): badge.id
        }
    }
}

private extension RecordKind {
    var idKey: String {
        switch self {
        case .longestDistance: "longestDistance"
        case .fastestOneKilometer: "fastestOneKilometer"
        case .fastestFiveKilometers: "fastestFiveKilometers"
        case .bestAveragePace: "bestAveragePace"
        }
    }
}

enum TrophyMath {
    private struct Ladder {
        let kind: BadgeKind
        let scope: BadgeScope
        let thresholds: [Double]
    }

    private struct Totals {
        var distance: Double = 0
        var count: Double = 0
    }

    private static let distanceThresholds = [10.0, 25, 50, 100, 250, 500, 1000]
    private static let bikeDistanceThresholds = [25.0, 50, 100, 250, 500, 1000, 2500]
    private static let countThresholds = [10.0, 25, 50, 100]

    static func allBadges(_ summaries: [ActivityWorkoutSummary]) -> [Badge] {
        let ladders = allLadders
        var totals = Dictionary(uniqueKeysWithValues: ([BadgeScope.global] + ActivityType.allCases.map { BadgeScope.perType($0) })
            .map { ($0, Totals()) })
        var earnedDates: [String: Date] = [:]

        for summary in summaries.sorted(by: chronologicalOrder) {
            add(summary, to: &totals, scope: .global)
            add(summary, to: &totals, scope: .perType(summary.type))

            for ladder in ladders where ladder.scope == .global || ladder.scope == .perType(summary.type) {
                let current = value(for: ladder.kind, totals: totals[ladder.scope] ?? Totals())
                for threshold in ladder.thresholds where current >= threshold {
                    let id = badgeID(kind: ladder.kind, scope: ladder.scope, threshold: threshold)
                    if earnedDates[id] == nil {
                        earnedDates[id] = summary.date
                    }
                }
            }
        }

        return ladders.flatMap { ladder in
            let current = value(for: ladder.kind, totals: totals[ladder.scope] ?? Totals())
            let nextUnearned = ladder.thresholds.first { current < $0 }
            return ladder.thresholds.map { threshold in
                let id = badgeID(kind: ladder.kind, scope: ladder.scope, threshold: threshold)
                let earned = current >= threshold
                let progress: Double
                if earned {
                    progress = 1
                } else if threshold == nextUnearned {
                    progress = min(max(current / threshold, 0), 1)
                } else {
                    progress = 0
                }
                return Badge(id: id,
                             kind: ladder.kind,
                             scope: ladder.scope,
                             threshold: threshold,
                             earned: earned,
                             progress: progress,
                             earnedAt: earnedDates[id])
            }
        }
    }

    static func achievements(history: [ActivityWorkoutSummary],
                             candidate: ActivityWorkoutSummary) -> [Achievement] {
        let candidateHistory = history + [candidate]
        var achievements: [Achievement] = []

        if history.contains(where: { $0.type == candidate.type }) {
            let priorRecords = Dictionary(uniqueKeysWithValues:
                ActivityStats.typeRecords(history, type: candidate.type).map { ($0.kind, $0) })
            let candidateRecords = ActivityStats.typeRecords(candidateHistory, type: candidate.type)
            achievements += candidateRecords.compactMap { record in
                guard record.workoutID == candidate.id,
                      isStrictlyBetter(record, than: priorRecords[record.kind]) else {
                    return nil
                }
                return Achievement(kind: .newRecord(record), recordType: candidate.type)
            }
        }

        let priorBadgeIDs = Set(allBadges(history).filter(\.earned).map(\.id))
        let newBadges = allBadges(candidateHistory)
            .filter { $0.earned && !priorBadgeIDs.contains($0.id) }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.threshold == rhs.element.threshold
                    ? lhs.offset < rhs.offset
                    : lhs.element.threshold < rhs.element.threshold
            }
            .map(\.element)
        achievements += newBadges.map { Achievement(kind: .newBadge($0)) }

        return achievements
    }

    static func nextMilestone(_ summaries: [ActivityWorkoutSummary]) -> Badge? {
        guard !summaries.isEmpty else { return nil }
        return allBadges(summaries)
            .filter { !$0.earned }
            .max { lhs, rhs in
                if lhs.progress == rhs.progress {
                    return lhs.threshold < rhs.threshold
                }
                return lhs.progress < rhs.progress
            }
    }

    private static let weeklyStreakThresholds = [4.0, 12]

    /// Weekly consistency badges, derived from GoalsMath.completedWeeks over all
    /// history — past qualifying weeks mint retroactively, like the Trophy Room backfill.
    static func weeklyBadges(_ weeks: [CompletedWeek], calendar: Calendar) -> [Badge] {
        let sorted = weeks.sorted { $0.weekStart < $1.weekStart }

        var longest = 0
        var run = 0
        var previous: Date?
        var streakEarnedAt: [Double: Date] = [:]
        for week in sorted {
            if let previous, calendar.date(byAdding: .day, value: 7, to: previous) == week.weekStart {
                run += 1
            } else {
                run = 1
            }
            previous = week.weekStart
            longest = max(longest, run)
            for threshold in weeklyStreakThresholds
            where run == Int(threshold) && streakEarnedAt[threshold] == nil {
                streakEarnedAt[threshold] = week.completedOn
            }
        }

        let firstID = badgeID(kind: .weeklyGoal, scope: .global, threshold: 1)
        var badges = [Badge(id: firstID,
                            kind: .weeklyGoal,
                            scope: .global,
                            threshold: 1,
                            earned: !sorted.isEmpty,
                            progress: sorted.isEmpty ? 0 : 1,
                            earnedAt: sorted.first?.completedOn)]

        let nextUnearned = weeklyStreakThresholds.first { Double(longest) < $0 }
        badges += weeklyStreakThresholds.map { threshold in
            let earned = Double(longest) >= threshold
            let progress: Double
            if earned {
                progress = 1
            } else if threshold == nextUnearned {
                progress = min(max(Double(longest) / threshold, 0), 1)
            } else {
                progress = 0
            }
            return Badge(id: badgeID(kind: .weeklyStreak, scope: .global, threshold: threshold),
                         kind: .weeklyStreak,
                         scope: .global,
                         threshold: threshold,
                         earned: earned,
                         progress: progress,
                         earnedAt: streakEarnedAt[threshold])
        }
        return badges
    }

    private static var allLadders: [Ladder] {
        [
            Ladder(kind: .distance, scope: .global, thresholds: distanceThresholds),
            Ladder(kind: .count, scope: .global, thresholds: countThresholds),
            Ladder(kind: .distance, scope: .perType(.run), thresholds: distanceThresholds),
            Ladder(kind: .count, scope: .perType(.run), thresholds: countThresholds),
            Ladder(kind: .distance, scope: .perType(.walk), thresholds: distanceThresholds),
            Ladder(kind: .count, scope: .perType(.walk), thresholds: countThresholds),
            Ladder(kind: .distance, scope: .perType(.bike), thresholds: bikeDistanceThresholds),
            Ladder(kind: .count, scope: .perType(.bike), thresholds: countThresholds)
        ]
    }

    private static func add(_ summary: ActivityWorkoutSummary, to totals: inout [BadgeScope: Totals],
                            scope: BadgeScope) {
        var current = totals[scope] ?? Totals()
        current.distance += summary.distanceMeters / 1000.0
        current.count += 1
        totals[scope] = current
    }

    private static func value(for kind: BadgeKind, totals: Totals) -> Double {
        switch kind {
        case .distance: totals.distance
        case .count: totals.count
        // Weekly badges are computed by weeklyBadges(_:calendar:), never via ladders.
        case .weeklyGoal, .weeklyStreak: 0
        }
    }

    private static func badgeID(kind: BadgeKind, scope: BadgeScope, threshold: Double) -> String {
        "\(kind.rawValue).\(scope.key).\(Int(threshold))"
    }

    private static func chronologicalOrder(_ lhs: ActivityWorkoutSummary,
                                           _ rhs: ActivityWorkoutSummary) -> Bool {
        lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date < rhs.date
    }

    private static func isStrictlyBetter(_ candidate: PersonalRecord,
                                         than previous: PersonalRecord?) -> Bool {
        guard let previous else { return true }
        return switch candidate.kind {
        case .longestDistance:
            candidate.value > previous.value
        case .fastestOneKilometer, .fastestFiveKilometers, .bestAveragePace:
            candidate.value < previous.value
        }
    }
}
