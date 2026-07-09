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
    private let activeEnergyType = HKQuantityType(.activeEnergyBurned)
    private let heightType = HKQuantityType(.height)
    private let bodyMassType = HKQuantityType(.bodyMass)

    static let pointsMetadataKey = "com.farid.runner.points"

    private var shareTypes: Set<HKSampleType> {
        [workoutType, routeType, distanceWalkRun, distanceCycling]
    }
    private var readTypes: Set<HKObjectType> {
        [stepType, workoutType, routeType, distanceWalkRun, distanceCycling,
         activeEnergyType, heightType, bodyMassType,
         HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex)]
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

    func earliestHistoryDate() async throws -> Date? {
        async let earliestWorkout = earliestSampleDate(for: workoutType)
        async let earliestSteps = earliestSampleDate(for: stepType)
        let workoutDate = try await earliestWorkout
        let stepsDate = try await earliestSteps
        return [workoutDate, stepsDate].compactMap { $0 }.min()
    }

    func diagnosticsReport() async -> String {
        var lines: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        // Read-authorization is deliberately obscured by HealthKit, so the real signal
        // is how much actually comes back — but include the coarse status too.
        func authName(_ s: HKAuthorizationStatus) -> String {
            switch s {
            case .notDetermined: "notDetermined"
            case .sharingDenied: "denied/unknown"
            case .sharingAuthorized: "authorized"
            @unknown default: "?"
            }
        }
        lines.append("Auth (read is obscured by iOS):")
        lines.append("  workouts: \(authName(store.authorizationStatus(for: workoutType)))")
        lines.append("  distCycling: \(authName(store.authorizationStatus(for: distanceCycling)))")
        lines.append("  distWalkRun: \(authName(store.authorizationStatus(for: distanceWalkRun)))")
        lines.append("  steps: \(authName(store.authorizationStatus(for: stepType)))")

        do {
            let earliestWorkout = try await earliestSampleDate(for: workoutType)
            let earliestStep = try await earliestSampleDate(for: stepType)
            lines.append("Earliest workout: \(earliestWorkout.map { df.string(from: $0) } ?? "none")")
            lines.append("Earliest step: \(earliestStep.map { df.string(from: $0) } ?? "none")")
        } catch {
            lines.append("Earliest dates: ERROR \(error.localizedDescription)")
        }

        // All workouts over ~10 years, tallied by their raw HK activity type, with how
        // many carry a readable distance (cycling / walk-run / aggregate total).
        do {
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: -3650, to: cal.startOfDay(for: Date()))!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
            let samples: [HKSample] = try await withCheckedThrowingContinuation { cont in
                let q = HKSampleQuery(sampleType: workoutType, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: s ?? []) }
                }
                store.execute(q)
            }
            let workouts = samples.compactMap { $0 as? HKWorkout }
            lines.append("Workouts in 3650d: \(workouts.count)")
            var byType: [UInt: Int] = [:]
            var byTypeWithDistance: [UInt: Int] = [:]
            var sources: Set<String> = []
            for w in workouts {
                let raw = w.workoutActivityType.rawValue
                byType[raw, default: 0] += 1
                let meters = workoutDistanceMeters(w, type: HealthMappers.activityType(from: w.workoutActivityType) ?? .run)
                if meters > 0 { byTypeWithDistance[raw, default: 0] += 1 }
                sources.insert(w.sourceRevision.source.name)
            }
            for raw in byType.keys.sorted() {
                lines.append("  type \(raw) (\(activityTypeName(raw))): \(byType[raw] ?? 0) total, \(byTypeWithDistance[raw] ?? 0) with distance")
            }

            let cyclingSamples = workouts.filter { $0.workoutActivityType == .cycling }.prefix(5)
            if !cyclingSamples.isEmpty {
                lines.append("Sample cycling workouts (first \(cyclingSamples.count)):")
                for w in cyclingSamples {
                    let type = HealthMappers.activityType(from: w.workoutActivityType) ?? .bike
                    let cyc = w.statistics(for: distanceCycling)?.sumQuantity()?.doubleValue(for: .meter())
                    let wr = w.statistics(for: distanceWalkRun)?.sumQuantity()?.doubleValue(for: .meter())
                    let agg = w.totalDistance?.doubleValue(for: .meter())
                    let kcal = workoutEnergyKcal(w)
                    let co2 = Co2Metadata.grams(from: w.metadata)
                    let keys = (w.metadata?.keys.sorted()).map { $0.joined(separator: ",") } ?? "none"
                    // Precompute into concrete Ints: a long chain of optional-map
                    // interpolations concatenated with `+` blows up Swift's type-checker.
                    let cycI = cyc.map { Int($0) } ?? -1
                    let wrI = wr.map { Int($0) } ?? -1
                    let aggI = agg.map { Int($0) } ?? -1
                    let usedI = Int(workoutDistanceMeters(w, type: type))
                    let kcalI = kcal.map { Int($0) } ?? -1
                    let co2I = co2.map { Int($0) } ?? -1
                    let durI = Int(w.duration)
                    lines.append("  \(df.string(from: w.startDate)) dur=\(durI)s dist[cyc=\(cycI),wr=\(wrI),agg=\(aggI)] used=\(usedI) kcal=\(kcalI) co2g=\(co2I)")
                    lines.append("    metaKeys: \(keys)")
                }
            }
            lines.append("Sources: \(sources.sorted().joined(separator: ", "))")
        } catch {
            lines.append("Workout scan: ERROR \(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    private func activityTypeName(_ raw: UInt) -> String {
        switch HKWorkoutActivityType(rawValue: raw) {
        case .running: "running"
        case .walking: "walking"
        case .cycling: "cycling"
        case .hiking: "hiking"
        case .some(let t): "hk#\(t.rawValue)"
        case .none: "unknown"
        }
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

    func walkRunDistance(from: Date, to: Date) async throws -> Double {
        guard to > from else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: distanceWalkRun,
                                          quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, stats, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: .meter()) ?? 0)
            }
            store.execute(query)
        }
    }

    func dailyWalkRunDistance(daysBack: Int) async throws -> [Date: Double] {
        let cal = Calendar.current
        let (start, end) = HealthMappers.window(daysBack: daysBack, endingAt: Date(), calendar: cal)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: distanceWalkRun,
                                                    quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum,
                                                    anchorDate: start,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var out: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let meters = stats.sumQuantity()?.doubleValue(for: .meter()) ?? 0
                    out[cal.startOfDay(for: stats.startDate)] = meters
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
            let realMeters = workoutDistanceMeters(workout, type: type)
            let estimatedMeters = realMeters == 0
                ? WorkoutEstimation.estimatedMeters(type: type, movingSeconds: workout.duration)
                : nil
            let meters = estimatedMeters ?? realMeters
            let energyKcal = workoutEnergyKcal(workout)
            let co2Grams = Co2Metadata.grams(from: workout.metadata)
            return ExternalWorkout(id: workout.uuid, type: type, start: workout.startDate,
                                   end: workout.endDate,
                                   movingSeconds: workout.duration,
                                   distanceMeters: meters,
                                   distanceEstimated: estimatedMeters != nil,
                                   activeEnergyKcal: energyKcal,
                                   co2SavedGrams: co2Grams,
                                   isFromThisApp: workout.sourceRevision.source.bundleIdentifier == bundleID)
        }
    }

    /// Distance for an imported workout, resilient to how the source stored it.
    /// Cycling workouts frequently expose no per-type `distanceCycling` statistic
    /// (indoor rides, some third-party sources), which previously read as 0 km; fall
    /// back to the other distance type and finally to the workout's aggregate total.
    private func workoutDistanceMeters(_ workout: HKWorkout, type: ActivityType) -> Double {
        let primary = (type == .bike) ? distanceCycling : distanceWalkRun
        let secondary = (type == .bike) ? distanceWalkRun : distanceCycling
        for distanceType in [primary, secondary] {
            if let meters = workout.statistics(for: distanceType)?.sumQuantity()?
                .doubleValue(for: .meter()), meters > 0 {
                return meters
            }
        }
        return workout.totalDistance?.doubleValue(for: .meter()) ?? 0
    }

    /// Real active energy (kcal) for an imported workout, or nil when the source
    /// recorded none. Prefer the per-type statistic; fall back to the aggregate.
    private func workoutEnergyKcal(_ workout: HKWorkout) -> Double? {
        let unit = HKUnit.kilocalorie()
        if let kcal = workout.statistics(for: activeEnergyType)?.sumQuantity()?
            .doubleValue(for: unit), kcal > 0 {
            return kcal
        }
        if let kcal = workout.totalEnergyBurned?.doubleValue(for: unit), kcal > 0 {
            return kcal
        }
        return nil
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
            CLLocation(coordinate: $0.coordinate,
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: $0.t)
        }
        if locations.count >= 2 {
            // Best-effort: the workout is already committed above, so a failed route
            // attach must not throw — reporting failure here would make the caller
            // keep a pending copy and re-save a duplicate workout on every sync.
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
            do {
                try await routeBuilder.insertRouteData(locations)
                try await routeBuilder.finishRoute(with: hkWorkout, metadata: nil)
            } catch {}
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

    func bodyMetrics() async throws -> HealthBody {
        async let heightCm = latestQuantity(heightType, unit: .meterUnit(with: .centi))
        async let massKg = latestQuantity(bodyMassType, unit: .gramUnit(with: .kilo))
        let birth = try? store.dateOfBirthComponents().date
        let sex: BodySex = switch (try? store.biologicalSex().biologicalSex) ?? .notSet {
        case .male: .male
        case .female: .female
        default: .unspecified
        }
        return HealthBody(heightCm: try await heightCm, weightKg: try await massKg,
                          birthDate: birth, sex: sex)
    }

    private func latestQuantity(_ type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: sort) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func earliestSampleDate(for type: HKSampleType) async throws -> Date? {
        try await withCheckedThrowingContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: sort) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples?.first?.startDate)
            }
            store.execute(query)
        }
    }
}
