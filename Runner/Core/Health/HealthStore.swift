import Foundation
import HealthKit
import CoreLocation

@MainActor
final class HealthStore: HealthStoring {
    private let store = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)
    private let workoutType = HKObjectType.workoutType()
    private let routeType = HKSeriesType.workoutRoute()
    private let distanceWalkRun = HKQuantityType(.distanceWalkingRunning)
    private let distanceCycling = HKQuantityType(.distanceCycling)

    static let pointsMetadataKey = "com.farid.runner.points"

    private var shareTypes: Set<HKSampleType> {
        [workoutType, routeType, distanceWalkRun, distanceCycling]
    }
    private var readTypes: Set<HKObjectType> {
        [stepType, workoutType, routeType, distanceWalkRun, distanceCycling]
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var writeDenied: Bool { store.authorizationStatus(for: workoutType) == .sharingDenied }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    func shouldRequestAuthorization() async -> Bool {
        let status = try? await store.statusForAuthorizationRequest(toShare: shareTypes, read: readTypes)
        return status == .shouldRequest
    }

    func dailySteps(daysBack: Int) async throws -> [Date: Int] {
        let cal = Calendar.current
        let (start, end) = HealthMappers.window(daysBack: daysBack, endingAt: Date(), calendar: cal)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: stepType,
                                                    quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum,
                                                    anchorDate: start,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var out: [Date: Int] = [:]
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let steps = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    out[cal.startOfDay(for: stats.startDate)] = Int(steps)
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    func workouts(daysBack: Int) async throws -> [ExternalWorkout] {
        let cal = Calendar.current
        let (start, end) = HealthMappers.window(daysBack: daysBack, endingAt: Date(), calendar: cal)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                          ascending: true)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.farid.runner"
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout,
                  let type = HealthMappers.activityType(from: workout.workoutActivityType) else { return nil }
            let distanceType = (type == .bike) ? distanceCycling : distanceWalkRun
            let meters = workout.statistics(for: distanceType)?.sumQuantity()?
                .doubleValue(for: .meter()) ?? 0
            return ExternalWorkout(id: workout.uuid, type: type, start: workout.startDate,
                                   distanceMeters: meters,
                                   isFromThisApp: workout.sourceRevision.source.bundleIdentifier == bundleID)
        }
    }

    func saveWorkout(_ workout: RecordedWorkout, points: Int) async throws -> UUID {
        let config = HKWorkoutConfiguration()
        config.activityType = HealthMappers.hkActivityType(for: workout.type)
        config.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: workout.start)

        if workout.distanceMeters > 0 {
            let distanceType = (workout.type == .bike) ? distanceCycling : distanceWalkRun
            let sample = HKQuantitySample(type: distanceType,
                                          quantity: HKQuantity(unit: .meter(),
                                                               doubleValue: workout.distanceMeters),
                                          start: workout.start, end: workout.end)
            try await builder.addSamples([sample])
        }
        try await builder.addMetadata([Self.pointsMetadataKey: points])
        try await builder.endCollection(at: workout.end)
        // SDK note: async finishWorkout() is optional in current SDKs; if this SDK
        // version returns non-optional, drop the guard and bind directly.
        guard let hkWorkout = try await builder.finishWorkout() else {
            throw NSError(domain: "Runner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HealthKit returned no workout"])
        }

        // Attach the GPS route (needs ≥2 locations).
        let locations = workout.route.map {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: $0.t)
        }
        if locations.count >= 2 {
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
            try await routeBuilder.insertRouteData(locations)
            try await routeBuilder.finishRoute(with: hkWorkout, metadata: nil)
        }
        return hkWorkout.uuid
    }

    func startObservingSteps(_ onChange: @escaping @Sendable () -> Void) {
        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { _, completion, _ in
            onChange()
            completion()
        }
        store.execute(query)
        store.enableBackgroundDelivery(for: stepType, frequency: .hourly) { _, _ in }
    }
}
