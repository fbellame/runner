import Foundation

/// Grams of car tailpipe CO2 avoided by covering distance under human power.
/// Bike-only: this is the Bixi "green impact" framing. Foundation-only, pure.
enum CO2Estimator {
    /// Average passenger-car tailpipe CO2, grams per km. Named for easy tuning.
    static let carGramsPerKm = 192.0

    static func avoidedGrams(type: ActivityType, distanceMeters: Double) -> Double {
        guard type == .bike, distanceMeters > 0 else { return 0 }
        return (distanceMeters / 1000.0) * carGramsPerKm
    }
}
