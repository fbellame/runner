import Foundation

struct ActivityWorkoutSummary {
    let id: UUID
    let type: ActivityType
    let date: Date
    let distanceMeters: Double
    let distanceEstimated: Bool
    let movingSeconds: Double
    let points: Int
    let calories: Double
    let splitSeconds: [Double]
    let hasRoute: Bool
    let co2SavedGrams: Double

    init(id: UUID, type: ActivityType, date: Date, distanceMeters: Double,
         distanceEstimated: Bool = false, movingSeconds: Double, points: Int,
         calories: Double, splitSeconds: [Double], hasRoute: Bool,
         co2SavedGrams: Double = 0) {
        self.id = id
        self.type = type
        self.date = date
        self.distanceMeters = distanceMeters
        self.distanceEstimated = distanceEstimated
        self.movingSeconds = movingSeconds
        self.points = points
        self.calories = calories
        self.splitSeconds = splitSeconds
        self.hasRoute = hasRoute
        self.co2SavedGrams = co2SavedGrams
    }
}

struct TypeStats {
    let sessions: Int
    let totalDistanceMeters: Double
    let totalMovingSeconds: Double
    let totalCalories: Double
    let totalPoints: Int
    let bestPaceSecPerKm: Double?
    let avgPaceSecPerKm: Double?
    let longestDistanceMeters: Double
    let weeklyDistance: [(weekStart: Date, meters: Double)]
}

struct LifetimeTotals {
    let distanceMeters: Double
    let movingSeconds: Double
    let calories: Double
    let workouts: Int
    let routesPainted: Int
    let co2SavedGrams: Double
    let perType: [ActivityType: (distanceMeters: Double, workouts: Int)]
}

struct PersonalRecord: Equatable, Sendable {
    let kind: RecordKind
    let value: Double
    let distanceEstimated: Bool
    let workoutID: UUID?
    let date: Date?

    init(kind: RecordKind, value: Double, distanceEstimated: Bool = false,
         workoutID: UUID?, date: Date?) {
        self.kind = kind
        self.value = value
        self.distanceEstimated = distanceEstimated
        self.workoutID = workoutID
        self.date = date
    }
}

enum RecordKind: CaseIterable, Equatable, Sendable {
    case longestDistance
    case fastestOneKilometer
    case fastestFiveKilometers
    case bestAveragePace
}

struct Milestone {
    let kind: MilestoneKind
    let threshold: Double
    let earned: Bool
    let progress: Double
}

enum MilestoneKind {
    case totalDistance
    case workoutCount
}

enum ActivityStats {
    static func typeStats(_ summaries: [ActivityWorkoutSummary], type: ActivityType,
                          calendar: Calendar) -> TypeStats {
        let scoped = summaries.filter { $0.type == type }
        let totalDistance = scoped.reduce(0) { $0 + $1.distanceMeters }
        let totalMovingSeconds = scoped.reduce(0) { $0 + $1.movingSeconds }
        let totalCalories = scoped.reduce(0) { $0 + $1.calories }
        let totalPoints = scoped.reduce(0) { $0 + $1.points }
        let paced = scoped.filter { $0.distanceMeters > 0 && $0.movingSeconds > 0 }
        let bestPace = paced.map { paceSecondsPerKm($0) }.min()
        let pacedDistance = paced.reduce(0) { $0 + $1.distanceMeters }
        let pacedSeconds = paced.reduce(0) { $0 + $1.movingSeconds }
        let avgPace = pacedDistance > 0 ? pacedSeconds / (pacedDistance / 1000.0) : nil
        let longest = scoped.map(\.distanceMeters).max() ?? 0

        var weeklyMeters: [Date: Double] = [:]
        for summary in scoped {
            let start = WeekMath.mondayStart(for: summary.date, calendar: calendar)
            weeklyMeters[start, default: 0] += summary.distanceMeters
        }

        return TypeStats(sessions: scoped.count,
                         totalDistanceMeters: totalDistance,
                         totalMovingSeconds: totalMovingSeconds,
                         totalCalories: totalCalories,
                         totalPoints: totalPoints,
                         bestPaceSecPerKm: bestPace,
                         avgPaceSecPerKm: avgPace,
                         longestDistanceMeters: longest,
                         weeklyDistance: weeklyMeters
                            .map { (weekStart: $0.key, meters: $0.value) }
                            .sorted { $0.weekStart < $1.weekStart })
    }

    static func lifetimeTotals(_ summaries: [ActivityWorkoutSummary]) -> LifetimeTotals {
        var perType = Dictionary(uniqueKeysWithValues: ActivityType.allCases.map {
            ($0, (distanceMeters: 0.0, workouts: 0))
        })

        for summary in summaries {
            let current = perType[summary.type] ?? (distanceMeters: 0, workouts: 0)
            perType[summary.type] = (distanceMeters: current.distanceMeters + summary.distanceMeters,
                                     workouts: current.workouts + 1)
        }

        return LifetimeTotals(distanceMeters: summaries.reduce(0) { $0 + $1.distanceMeters },
                              movingSeconds: summaries.reduce(0) { $0 + $1.movingSeconds },
                              calories: summaries.reduce(0) { $0 + $1.calories },
                              workouts: summaries.count,
                              routesPainted: summaries.filter(\.hasRoute).count,
                              co2SavedGrams: summaries.reduce(0) { $0 + $1.co2SavedGrams },
                              perType: perType)
    }

    static func typeRecords(_ summaries: [ActivityWorkoutSummary], type: ActivityType) -> [PersonalRecord] {
        let scoped = summaries.filter { $0.type == type }
        guard !scoped.isEmpty else { return [] }

        var records: [PersonalRecord] = []

        if let longest = scoped.max(by: { $0.distanceMeters < $1.distanceMeters }) {
            records.append(PersonalRecord(kind: .longestDistance,
                                          value: longest.distanceMeters,
                                          distanceEstimated: longest.distanceEstimated,
                                          workoutID: longest.id,
                                          date: longest.date))
        }

        if let fastestOne = fastestSplit(in: scoped) {
            records.append(PersonalRecord(kind: .fastestOneKilometer,
                                          value: fastestOne.seconds,
                                          workoutID: fastestOne.summary.id,
                                          date: fastestOne.summary.date))
        }

        if let fastestFive = fastestFiveKilometerWindow(in: scoped) {
            records.append(PersonalRecord(kind: .fastestFiveKilometers,
                                          value: fastestFive.seconds,
                                          workoutID: fastestFive.summary.id,
                                          date: fastestFive.summary.date))
        }

        if let bestAverage = scoped
            .filter({ $0.distanceMeters >= 1000 && $0.movingSeconds > 0 })
            .min(by: { paceSecondsPerKm($0) < paceSecondsPerKm($1) }) {
            records.append(PersonalRecord(kind: .bestAveragePace,
                                          value: paceSecondsPerKm(bestAverage),
                                          workoutID: bestAverage.id,
                                          date: bestAverage.date))
        }

        return records
    }

    static func milestones(_ totals: LifetimeTotals) -> [Milestone] {
        milestoneTrack(kind: .totalDistance,
                       thresholds: [10, 25, 50, 100, 250, 500, 1000],
                       current: totals.distanceMeters / 1000.0)
        + milestoneTrack(kind: .workoutCount,
                         thresholds: [10, 25, 50, 100],
                         current: Double(totals.workouts))
    }

    private static func paceSecondsPerKm(_ summary: ActivityWorkoutSummary) -> Double {
        summary.movingSeconds / (summary.distanceMeters / 1000.0)
    }

    private static func fastestSplit(in summaries: [ActivityWorkoutSummary])
    -> (summary: ActivityWorkoutSummary, seconds: Double)? {
        var best: (summary: ActivityWorkoutSummary, seconds: Double)?
        for summary in summaries {
            for split in summary.splitSeconds {
                if best == nil || split < best!.seconds {
                    best = (summary, split)
                }
            }
        }
        return best
    }

    private static func fastestFiveKilometerWindow(in summaries: [ActivityWorkoutSummary])
    -> (summary: ActivityWorkoutSummary, seconds: Double)? {
        var best: (summary: ActivityWorkoutSummary, seconds: Double)?

        for summary in summaries where summary.splitSeconds.count >= 5 {
            for start in 0...(summary.splitSeconds.count - 5) {
                let seconds = summary.splitSeconds[start..<(start + 5)].reduce(0, +)
                if best == nil || seconds < best!.seconds {
                    best = (summary, seconds)
                }
            }
        }

        return best
    }

    private static func milestoneTrack(kind: MilestoneKind, thresholds: [Double],
                                       current: Double) -> [Milestone] {
        let nextUnearned = thresholds.first { current < $0 }
        return thresholds.map { threshold in
            let earned = current >= threshold
            let progress: Double
            if earned {
                progress = 1
            } else if threshold == nextUnearned {
                progress = threshold > 0 ? min(max(current / threshold, 0), 1) : 0
            } else {
                progress = 0
            }

            return Milestone(kind: kind,
                             threshold: threshold,
                             earned: earned,
                             progress: progress)
        }
    }
}
