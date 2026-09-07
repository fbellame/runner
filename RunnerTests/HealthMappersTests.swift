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

    // MARK: Which distance statistic wins
    //
    // This chain exists because of a real field defect: Bixi rides carried no
    // `distanceCycling` statistic and imported as 0.00 km. Until it was lifted
    // out of `HealthStore` it sat on an `HKWorkout`, which cannot be
    // constructed outside HealthKit — so it was verified only by running
    // outside with a phone.

    @Test func distancePrefersThePerTypeStatisticForTheActivity() {
        #expect(HealthMappers.resolvedDistanceMeters(
            type: .bike, cyclingMeters: 10_000, walkRunMeters: 42, totalMeters: 7) == 10_000)
        #expect(HealthMappers.resolvedDistanceMeters(
            type: .run, cyclingMeters: 42, walkRunMeters: 5_000, totalMeters: 7) == 5_000)
        #expect(HealthMappers.resolvedDistanceMeters(
            type: .walk, cyclingMeters: 42, walkRunMeters: 2_000, totalMeters: 7) == 2_000)
    }

    /// The Bixi case. An indoor or third-party ride exposes no cycling
    /// statistic at all, and the ride used to import as 0.00 km — no points, no
    /// CO₂, no distance in the hub.
    @Test func distanceFallsBackToTheOtherTypeThenTheAggregate() {
        #expect(HealthMappers.resolvedDistanceMeters(
            type: .bike, cyclingMeters: nil, walkRunMeters: 9_000, totalMeters: 3) == 9_000)
        #expect(HealthMappers.resolvedDistanceMeters(
            type: .bike, cyclingMeters: nil, walkRunMeters: nil, totalMeters: 8_500) == 8_500)
        #expect(HealthMappers.resolvedDistanceMeters(
            type: .run, cyclingMeters: nil, walkRunMeters: nil, totalMeters: 4_200) == 4_200)
    }

    /// A statistic that is present but zero carries no more information than an
    /// absent one, so it must not win over a real number further down the chain.
    @Test func aZeroStatisticIsTreatedAsAbsent() {
        #expect(HealthMappers.resolvedDistanceMeters(
            type: .bike, cyclingMeters: 0, walkRunMeters: 6_000, totalMeters: 0) == 6_000)
        #expect(HealthMappers.resolvedDistanceMeters(
            type: .bike, cyclingMeters: 0, walkRunMeters: 0, totalMeters: 6_000) == 6_000)
    }

    @Test func distanceIsZeroOnlyWhenTheSourceRecordedNone() {
        #expect(HealthMappers.resolvedDistanceMeters(
            type: .run, cyclingMeters: nil, walkRunMeters: nil, totalMeters: nil) == 0)
    }

    // MARK: Which energy statistic wins

    /// `nil` and `0` are different answers and the caller depends on it: `nil`
    /// means "no source value, estimate it", while `0` would assert the workout
    /// burned nothing and freeze that into the row.
    @Test func energyDistinguishesNoValueFromZero() {
        #expect(HealthMappers.resolvedEnergyKcal(activeEnergyKcal: 420, totalEnergyKcal: 99) == 420)
        #expect(HealthMappers.resolvedEnergyKcal(activeEnergyKcal: nil, totalEnergyKcal: 310) == 310)
        #expect(HealthMappers.resolvedEnergyKcal(activeEnergyKcal: 0, totalEnergyKcal: 310) == 310)
        #expect(HealthMappers.resolvedEnergyKcal(activeEnergyKcal: nil, totalEnergyKcal: nil) == nil)
        #expect(HealthMappers.resolvedEnergyKcal(activeEnergyKcal: 0, totalEnergyKcal: 0) == nil)
    }
}
