import Foundation
import HealthKit

enum HealthMappers {
    static func activityType(from hk: HKWorkoutActivityType) -> ActivityType? {
        switch hk {
        case .running: .run
        case .walking: .walk
        case .cycling: .bike
        default: nil
        }
    }

    static func hkActivityType(for type: ActivityType) -> HKWorkoutActivityType {
        switch type {
        case .run: .running
        case .walk: .walking
        case .bike: .cycling
        }
    }

    static func window(daysBack: Int, endingAt now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let start = calendar.date(byAdding: .day, value: -(daysBack - 1),
                                  to: calendar.startOfDay(for: now))!
        return (start, now)
    }

    /// Which of a workout's distance statistics to believe, and in what order.
    ///
    /// Lifted out of `HealthStore` so it can be tested: an `HKWorkout` cannot be
    /// constructed outside HealthKit, so as long as this branching lived on one
    /// it was reachable only from a real phone — and it exists *because* of a
    /// field bug (Bixi rides reading 0 km). What a test cannot reach is reading
    /// the three statistics off the sample; what it needs to reach is this
    /// decision. They are now separate.
    ///
    /// Cycling workouts frequently expose no `distanceCycling` statistic —
    /// indoor rides, some third-party sources — so fall back to the other
    /// distance type and finally to the workout's aggregate total. A statistic
    /// that is present but zero carries no more information than an absent one.
    static func resolvedDistanceMeters(type: ActivityType,
                                       cyclingMeters: Double?,
                                       walkRunMeters: Double?,
                                       totalMeters: Double?) -> Double {
        let primary = (type == .bike) ? cyclingMeters : walkRunMeters
        let secondary = (type == .bike) ? walkRunMeters : cyclingMeters
        for candidate in [primary, secondary] {
            if let meters = candidate, meters > 0 { return meters }
        }
        return totalMeters ?? 0
    }

    /// Real active energy for an imported workout, or `nil` when the source
    /// recorded none — which is a different answer from zero, and the caller
    /// relies on the difference: `nil` means "estimate it", `0` would mean "this
    /// workout burned nothing". Prefer the per-type statistic, fall back to the
    /// aggregate.
    static func resolvedEnergyKcal(activeEnergyKcal: Double?,
                                   totalEnergyKcal: Double?) -> Double? {
        for candidate in [activeEnergyKcal, totalEnergyKcal] {
            if let kcal = candidate, kcal > 0 { return kcal }
        }
        return nil
    }

    static func groupByDay(_ workouts: [ExternalWorkout], calendar: Calendar) -> [Date: [WorkoutSummary]] {
        var out: [Date: [WorkoutSummary]] = [:]
        for w in workouts.sorted(by: { $0.start < $1.start }) {
            let day = calendar.startOfDay(for: w.start)
            out[day, default: []].append(WorkoutSummary(type: w.type, distanceMeters: w.distanceMeters))
        }
        return out
    }
}
