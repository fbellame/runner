import Foundation
import SwiftData

@Model
final class DayLedger {
    @Attribute(.unique) var date: Date
    var steps: Int
    var stepPoints: Int
    var workoutPoints: Int
    var multiplier: Double
    var totalPoints: Int
    var goalAtThatTime: Int
    var isGold: Bool
    var streakAfter: Int

    init(date: Date, steps: Int, stepPoints: Int, workoutPoints: Int, multiplier: Double,
         totalPoints: Int, goalAtThatTime: Int, isGold: Bool, streakAfter: Int) {
        self.date = date
        self.steps = steps
        self.stepPoints = stepPoints
        self.workoutPoints = workoutPoints
        self.multiplier = multiplier
        self.totalPoints = totalPoints
        self.goalAtThatTime = goalAtThatTime
        self.isGold = isGold
        self.streakAfter = streakAfter
    }

    func apply(_ day: LedgerDay) {
        steps = day.steps
        stepPoints = day.breakdown.stepPoints
        workoutPoints = day.breakdown.workoutPoints
        multiplier = day.breakdown.multiplier
        totalPoints = day.breakdown.total
        goalAtThatTime = day.goal
        isGold = day.isGold
        streakAfter = day.streakAfter
    }
}

@Model
final class WorkoutRec {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var start: Date
    var end: Date
    var movingSeconds: Double
    var distanceMeters: Double
    var points: Int
    var routeData: Data?
    var splitSeconds: [Double]
    var source: String        // "runner" | "external"
    var hkSynced: Bool

    var type: ActivityType { ActivityType(rawValue: typeRaw) ?? .run }

    init(id: UUID, typeRaw: String, start: Date, end: Date, movingSeconds: Double,
         distanceMeters: Double, points: Int, routeData: Data?, splitSeconds: [Double],
         source: String, hkSynced: Bool) {
        self.id = id
        self.typeRaw = typeRaw
        self.start = start
        self.end = end
        self.movingSeconds = movingSeconds
        self.distanceMeters = distanceMeters
        self.points = points
        self.routeData = routeData
        self.splitSeconds = splitSeconds
        self.source = source
        self.hkSynced = hkSynced
    }
}
