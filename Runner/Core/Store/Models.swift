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
    // Derived, recomputed by the ledger-rebuild path (SyncCoordinator). Cache-safe.
    // Inline defaults let SwiftData lightweight-migrate an existing v1 store by
    // backfilling these columns on rows written before v1.1.
    var activeCalories: Double = 0
    var distanceMeters: Double = 0
    var activeSeconds: Double = 0

    init(date: Date, steps: Int, stepPoints: Int, workoutPoints: Int, multiplier: Double,
         totalPoints: Int, goalAtThatTime: Int, isGold: Bool, streakAfter: Int,
         activeCalories: Double = 0, distanceMeters: Double = 0, activeSeconds: Double = 0) {
        self.date = date
        self.steps = steps
        self.stepPoints = stepPoints
        self.workoutPoints = workoutPoints
        self.multiplier = multiplier
        self.totalPoints = totalPoints
        self.goalAtThatTime = goalAtThatTime
        self.isGold = isGold
        self.streakAfter = streakAfter
        self.activeCalories = activeCalories
        self.distanceMeters = distanceMeters
        self.activeSeconds = activeSeconds
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
    // Persisted at save time from the body metrics in effect then, so a workout
    // keeps the calories it was burned at even if weight later changes.
    // Inline default backfills this column when migrating an existing v1 store.
    var calories: Double = 0

    var type: ActivityType { ActivityType(rawValue: typeRaw) ?? .run }

    init(id: UUID, typeRaw: String, start: Date, end: Date, movingSeconds: Double,
         distanceMeters: Double, points: Int, routeData: Data?, splitSeconds: [Double],
         source: String, hkSynced: Bool, calories: Double = 0) {
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
        self.calories = calories
    }
}

@Model
final class UserProfile {
    var heightCm: Double?
    var isHeightManual: Bool
    var weightKg: Double?
    var isWeightManual: Bool
    var birthDate: Date?
    var isBirthManual: Bool
    var sexRaw: String?
    var isSexManual: Bool

    init(heightCm: Double? = nil, isHeightManual: Bool = false,
         weightKg: Double? = nil, isWeightManual: Bool = false,
         birthDate: Date? = nil, isBirthManual: Bool = false,
         sexRaw: String? = nil, isSexManual: Bool = false) {
        self.heightCm = heightCm
        self.isHeightManual = isHeightManual
        self.weightKg = weightKg
        self.isWeightManual = isWeightManual
        self.birthDate = birthDate
        self.isBirthManual = isBirthManual
        self.sexRaw = sexRaw
        self.isSexManual = isSexManual
    }

    var sex: BodySex {
        get { sexRaw.flatMap(BodySex.init(rawValue:)) ?? .unspecified }
        set { sexRaw = newValue == .unspecified ? nil : newValue.rawValue }
    }

    var age: Int? {
        guard let birthDate else { return nil }
        return Calendar.current.dateComponents([.year], from: birthDate, to: .now).year
    }

    var bodyMetrics: BodyMetrics {
        BodyMetrics(weightKg: weightKg, heightCm: heightCm, sex: sex, age: age)
    }
}
