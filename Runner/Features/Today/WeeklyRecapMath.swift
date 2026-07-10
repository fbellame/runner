import Foundation

struct RecapLedgerDay {
    let date: Date
    let totalPoints: Int
    let isGold: Bool
}

struct BestRun: Equatable {
    let type: ActivityType
    let distanceMeters: Double
    let date: Date
}

struct WeeklyRecap: Equatable {
    let points: Int
    let pointsPrevious: Int
    let pointsDeltaFraction: Double?
    let distanceMeters: Double
    let sessions: Int
    let goldDays: Int
    let bestRun: BestRun?

    var hasActivity: Bool { points > 0 || sessions > 0 || distanceMeters > 0 }
}

enum WeeklyRecapMath {
    static func recap(ledgers: [RecapLedgerDay],
                      workouts: [ActivityWorkoutSummary],
                      now: Date,
                      calendar: Calendar) -> WeeklyRecap {
        let currentStart = WeekMath.mondayStart(for: now, calendar: calendar)
        let today0 = calendar.startOfDay(for: now)
        let previousStart = calendar.date(byAdding: .day, value: -7, to: currentStart)!
        let previousToday0 = calendar.date(byAdding: .day, value: -7, to: today0)!

        // Ledgers are whole-day buckets: compare by start-of-day ranges.
        var points = 0
        var pointsPrevious = 0
        var goldDays = 0
        for ledger in ledgers {
            let day = calendar.startOfDay(for: ledger.date)
            if day >= currentStart && day <= today0 {
                points += ledger.totalPoints
                if ledger.isGold { goldDays += 1 }
            } else if day >= previousStart && day <= previousToday0 {
                pointsPrevious += ledger.totalPoints
            }
        }

        let deltaFraction: Double?
        if pointsPrevious > 0 {
            deltaFraction = Double(points - pointsPrevious) / Double(pointsPrevious)
        } else {
            deltaFraction = nil
        }

        // Workouts use the exact timestamp window [currentStart, now].
        let currentWorkouts = workouts.filter { $0.date >= currentStart && $0.date <= now }
        let distanceMeters = currentWorkouts.reduce(0.0) { $0 + $1.distanceMeters }
        let sessions = currentWorkouts.count

        // Greatest distance wins; ties resolve to the earliest run, independent of
        // the input order.
        var bestRun: BestRun?
        for workout in currentWorkouts {
            let isBetter: Bool
            if let current = bestRun {
                isBetter = workout.distanceMeters > current.distanceMeters
                    || (workout.distanceMeters == current.distanceMeters && workout.date < current.date)
            } else {
                isBetter = true
            }
            if isBetter {
                bestRun = BestRun(type: workout.type,
                                  distanceMeters: workout.distanceMeters,
                                  date: workout.date)
            }
        }

        return WeeklyRecap(points: points,
                           pointsPrevious: pointsPrevious,
                           pointsDeltaFraction: deltaFraction,
                           distanceMeters: distanceMeters,
                           sessions: sessions,
                           goldDays: goldDays,
                           bestRun: bestRun)
    }
}
