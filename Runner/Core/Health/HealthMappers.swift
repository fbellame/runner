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

    static func groupByDay(_ workouts: [ExternalWorkout], calendar: Calendar) -> [Date: [WorkoutSummary]] {
        var out: [Date: [WorkoutSummary]] = [:]
        for w in workouts.sorted(by: { $0.start < $1.start }) {
            let day = calendar.startOfDay(for: w.start)
            out[day, default: []].append(WorkoutSummary(type: w.type, distanceMeters: w.distanceMeters))
        }
        return out
    }
}
