import Foundation

enum BodySex: String, Sendable {
    case male, female, unspecified
}

struct BodyMetrics: Equatable, Sendable {
    let weightKg: Double?
    let heightCm: Double?
    let sex: BodySex
    let age: Int?
}

struct WorkoutEnergyInput: Equatable, Sendable {
    let type: ActivityType
    let distanceMeters: Double
    let movingSeconds: Double
    /// Real active energy from Health, when the source recorded it; else nil → MET estimate.
    let realKcal: Double?

    init(type: ActivityType, distanceMeters: Double, movingSeconds: Double,
         realKcal: Double? = nil) {
        self.type = type
        self.distanceMeters = distanceMeters
        self.movingSeconds = movingSeconds
        self.realKcal = realKcal
    }
}

struct CalorieBreakdown: Equatable, Sendable {
    let everydayKcal: Double
    let workoutKcal: [Double]   // same order as the input workouts
    var total: Double { everydayKcal + workoutKcal.reduce(0, +) }
}

/// Pure energy-expenditure estimator. MET × body-mass × time, no heart-rate sensor.
/// Values are estimates; callers label them as such and never show them without a weight.
enum CalorieEngine {
    // Everyday (non-workout) step assumptions.
    static let everydayWalkMET = 3.0
    static let everydayWalkSpeedKmh = 4.5

    // Speed→MET breakpoints (km/h, MET), from the Compendium of Physical Activities.
    // Piecewise-linear, clamped at both ends.
    private static let runTable: [(Double, Double)] = [
        (6.4, 6.0), (8.0, 8.3), (9.7, 9.8), (11.3, 11.0),
        (12.9, 11.8), (14.5, 12.8), (16.1, 14.5), (19.3, 19.0),
    ]
    // The (0.0, 1.3) anchor is "standing quietly" from the same Compendium. Without
    // it the table clamped at 2.0 km/h, so a walk session that stayed open while the
    // user stood still billed a genuine walking rate for the whole duration: one
    // real auto-walk covering 501 m in 188 minutes claimed 476 kcal. Interpolating
    // down to standing makes a stalled session cost roughly what standing costs.
    private static let walkTable: [(Double, Double)] = [
        (0.0, 1.3), (2.0, 2.0), (3.2, 2.8), (4.0, 3.0), (4.8, 3.5),
        (5.6, 4.3), (6.4, 5.0), (7.2, 6.3),
    ]
    private static let bikeTable: [(Double, Double)] = [
        (16.0, 4.0), (19.0, 8.0), (22.5, 10.0), (25.5, 12.0), (30.6, 15.8),
    ]

    private static func table(for type: ActivityType) -> [(Double, Double)] {
        switch type {
        case .run: runTable
        case .walk: walkTable
        case .bike: bikeTable
        }
    }

    static func met(type: ActivityType, speedKmh: Double) -> Double {
        let t = table(for: type)
        if speedKmh <= t.first!.0 { return t.first!.1 }
        if speedKmh >= t.last!.0 { return t.last!.1 }
        for i in 1..<t.count where speedKmh <= t[i].0 {
            let (x0, y0) = t[i - 1]
            let (x1, y1) = t[i]
            let f = (speedKmh - x0) / (x1 - x0)
            return y0 + f * (y1 - y0)
        }
        return t.last!.1
    }

    /// Stride length in meters. Height × sex factor; sex-based average when height is unknown.
    static func strideMeters(heightCm: Double?, sex: BodySex) -> Double {
        let factor: Double = switch sex {
        case .male: 0.415
        case .female: 0.413
        case .unspecified: 0.414
        }
        let h = heightCm ?? (sex == .female ? 162.0 : sex == .male ? 175.0 : 170.0)
        return (h / 100.0) * factor
    }

    static func metersToSteps(distanceMeters: Double, heightCm: Double?, sex: BodySex) -> Int {
        let stride = strideMeters(heightCm: heightCm, sex: sex)
        guard stride > 0 else { return 0 }
        return Int((distanceMeters / stride).rounded())
    }

    static func workoutCalories(type: ActivityType, distanceMeters: Double,
                                movingSeconds: Double, weightKg: Double) -> Double {
        guard distanceMeters > 0, movingSeconds > 0, weightKg > 0 else { return 0 }
        let speedKmh = (distanceMeters / 1000.0) / (movingSeconds / 3600.0)
        return met(type: type, speedKmh: speedKmh) * weightKg * (movingSeconds / 3600.0)
    }

    private static func kcalPerStep(weightKg: Double, stride: Double) -> Double {
        // Treat each step as everyday-pace walking: MET × weight × (strideKm / speedKmh) hours.
        (stride / 1000.0) * everydayWalkMET * weightKg / everydayWalkSpeedKmh
    }

    /// Full day breakdown, or nil when weight is unknown.
    static func dayCalories(steps: Int, workouts: [WorkoutEnergyInput],
                            metrics: BodyMetrics) -> CalorieBreakdown? {
        guard let weightKg = metrics.weightKg, weightKg > 0 else { return nil }

        let workoutKcal = workouts.map {
            $0.realKcal ?? workoutCalories(type: $0.type, distanceMeters: $0.distanceMeters,
                                           movingSeconds: $0.movingSeconds, weightKg: weightKg)
        }

        // De-duplicate: remove steps attributable to run/walk workouts (bike has none).
        let workoutFootMeters = workouts
            .filter { $0.type != .bike }
            .reduce(0.0) { $0 + $1.distanceMeters }
        let workoutSteps = metersToSteps(distanceMeters: workoutFootMeters,
                                         heightCm: metrics.heightCm, sex: metrics.sex)
        let everydaySteps = max(0, steps - workoutSteps)
        let stride = strideMeters(heightCm: metrics.heightCm, sex: metrics.sex)
        let everydayKcal = Double(everydaySteps) * kcalPerStep(weightKg: weightKg, stride: stride)

        return CalorieBreakdown(everydayKcal: everydayKcal, workoutKcal: workoutKcal)
    }
}
