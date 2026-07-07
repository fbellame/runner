import Testing
import Foundation
import HealthKit
@testable import Runner

struct HealthMappersTests {
    @Test func activityTypeMapping() {
        #expect(HealthMappers.activityType(from: .running) == .run)
        #expect(HealthMappers.activityType(from: .walking) == .walk)
        #expect(HealthMappers.activityType(from: .cycling) == .bike)
        #expect(HealthMappers.activityType(from: .yoga) == nil)
        #expect(HealthMappers.hkActivityType(for: .run) == .running)
        #expect(HealthMappers.hkActivityType(for: .walk) == .walking)
        #expect(HealthMappers.hkActivityType(for: .bike) == .cycling)
    }

    @Test func windowSpansRequestedDays() {
        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let (start, end) = HealthMappers.window(daysBack: 90, endingAt: now, calendar: cal)
        #expect(end == now)
        #expect(start == cal.date(byAdding: .day, value: -(90 - 1), to: cal.startOfDay(for: now)))
        // window includes today → 90 distinct days total
    }

    @Test func groupsWorkoutsByLocalDay() {
        let cal = Calendar.current
        let now = Date()
        let todayNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let yesterdayNoon = cal.date(byAdding: .day, value: -1, to: todayNoon)!
        let list = [
            ExternalWorkout(id: UUID(), type: .run, start: todayNoon, end: todayNoon.addingTimeInterval(1500),
                            movingSeconds: 1500, distanceMeters: 5000, isFromThisApp: false),
            ExternalWorkout(id: UUID(), type: .bike, start: todayNoon.addingTimeInterval(3600),
                            end: todayNoon.addingTimeInterval(5400), movingSeconds: 1800,
                            distanceMeters: 10_000, isFromThisApp: true),
            ExternalWorkout(id: UUID(), type: .walk, start: yesterdayNoon, end: yesterdayNoon.addingTimeInterval(1200),
                            movingSeconds: 1200, distanceMeters: 2000, isFromThisApp: false),
        ]
        let grouped = HealthMappers.groupByDay(list, calendar: cal)
        #expect(grouped[cal.startOfDay(for: todayNoon)]?.count == 2)
        #expect(grouped[cal.startOfDay(for: yesterdayNoon)] ==
                [WorkoutSummary(type: .walk, distanceMeters: 2000)])
    }
}
