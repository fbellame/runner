import Foundation

struct WorkoutSummary: Equatable, Sendable {
    let type: ActivityType
    let distanceMeters: Double
}

struct PointsBreakdown: Equatable, Sendable {
    let stepPoints: Int
    let workoutPoints: Int
    let multiplier: Double
    let total: Int
}

enum PointsEngine {
    static let stepDivisor = 100
    static let stepCap = 200
    static let streakBonusPerDay = 0.05
    static let multiplierCap = 1.5

    static func rate(for type: ActivityType) -> Double {
        switch type {
        case .run: 15
        case .walk: 10
        case .bike: 6
        }
    }

    static func stepPoints(steps: Int) -> Int {
        min(steps / stepDivisor, stepCap)
    }

    static func workoutPoints(type: ActivityType, distanceMeters: Double) -> Int {
        Int(((distanceMeters / 1000.0) * rate(for: type)).rounded())
    }

    static func multiplier(streakBefore: Int) -> Double {
        min(1.0 + streakBonusPerDay * Double(streakBefore), multiplierCap)
    }

    static func breakdown(steps: Int, workouts: [WorkoutSummary], streakBefore: Int) -> PointsBreakdown {
        let sp = stepPoints(steps: steps)
        let wp = workouts.reduce(0) { $0 + workoutPoints(type: $1.type, distanceMeters: $1.distanceMeters) }
        let m = multiplier(streakBefore: streakBefore)
        let total = Int((Double(sp + wp) * m).rounded())
        return PointsBreakdown(stepPoints: sp, workoutPoints: wp, multiplier: m, total: total)
    }

    /// Same rounding as workoutPoints so the live HUD never disagrees with the
    /// summary shown the moment the user finishes.
    static func livePoints(type: ActivityType, distanceMeters: Double) -> Int {
        workoutPoints(type: type, distanceMeters: distanceMeters)
    }
}
