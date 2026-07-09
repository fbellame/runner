import Foundation

@MainActor
final class SyncCoordinator {
    static let windowDays = 90
    private static let fullHistoryKey = "fullHistoryBackfilled"
    // v1.4 added real calories + CO₂ to imported workouts. Existing stores were
    // backfilled under v1.3 (fullHistoryKey already set), so a plain upgrade would
    // only refresh the rolling window and leave historical rides at co2 = 0. Force
    // one more full re-import the first time a v1.4 build syncs.
    private static let co2BackfillKey = "v14MetricsBackfilled"

    private let health: HealthStoring
    private let store: DataStore
    private let currentGoal: () -> Int
    private let metricsProvider: () -> BodyMetrics
    private let defaults: UserDefaults

    private(set) var lastError: String?
    private(set) var isSyncing = false
    private var rerunRequested = false
    private var isSavingRecorded = false

    init(health: HealthStoring, store: DataStore, currentGoal: @escaping () -> Int,
         metricsProvider: @escaping () -> BodyMetrics, defaults: UserDefaults = .standard) {
        self.health = health
        self.store = store
        self.currentGoal = currentGoal
        self.metricsProvider = metricsProvider
        self.defaults = defaults
    }

    static func daysBack(backfilled: Bool, earliest: Date?, now: Date, calendar: Calendar) -> Int {
        guard !backfilled else { return windowDays }
        guard let earliest else { return windowDays }

        let firstDay = calendar.startOfDay(for: earliest)
        let today = calendar.startOfDay(for: now)
        let span = (calendar.dateComponents([.day], from: firstDay, to: today).day ?? 0) + 1
        return max(span, windowDays)
    }

    func resetFullHistory() {
        defaults.set(false, forKey: Self.fullHistoryKey)
    }

    func syncNow() async {
        // A request landing mid-sync must not be lost: the in-flight pass already
        // read HealthKit, so queue one trailing rerun instead of dropping it.
        guard !isSyncing else {
            rerunRequested = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            rerunRequested = false
            await performSync()
        } while rerunRequested
    }

    /// Persists a freshly recorded workout: local store first (durable even if the
    /// app dies mid-save), then HealthKit, then mark synced under the same id —
    /// the one save path shared with retryPendingSaves. Returns an error message
    /// when the HealthKit save failed (the workout is kept locally and retried).
    @discardableResult
    func saveRecorded(_ workout: RecordedWorkout) async -> String? {
        guard !isSavingRecorded else { return nil }
        isSavingRecorded = true
        defer { isSavingRecorded = false }

        let points = PointsEngine.workoutPoints(type: workout.type,
                                                distanceMeters: workout.distanceMeters)
        let kcal = workoutCalories(type: workout.type, distanceMeters: workout.distanceMeters,
                                   movingSeconds: workout.movingSeconds, metrics: metricsProvider())
        let routeData = try? workout.route.encoded()
        let id = UUID()
        try? store.upsertWorkout(id: id, type: workout.type, start: workout.start,
                                 end: workout.end, movingSeconds: workout.movingSeconds,
                                 distanceMeters: workout.distanceMeters, points: points,
                                 routeData: routeData, splitSeconds: workout.splitSeconds,
                                 source: "runner", hkSynced: false, calories: kcal)
        var failure: String?
        do {
            _ = try await health.saveWorkout(workout, points: points)
            try? store.upsertWorkout(id: id, type: workout.type, start: workout.start,
                                     end: workout.end, movingSeconds: workout.movingSeconds,
                                     distanceMeters: workout.distanceMeters, points: points,
                                     routeData: routeData, splitSeconds: workout.splitSeconds,
                                     source: "runner", hkSynced: true, calories: kcal)
        } catch {
            failure = error.localizedDescription
        }
        await syncNow()
        return failure
    }

    private func performSync() async {
        lastError = nil
        await retryPendingSaves()

        do {
            let cal = Calendar.current
            let now = Date()
            // One-time v1.4 upgrade: re-open the full-history backfill so every
            // imported workout gets real calories + CO₂ (previously 0). Piggybacks on
            // the existing backfill machinery, which re-arms the rolling window after.
            if !defaults.bool(forKey: Self.co2BackfillKey) {
                defaults.set(false, forKey: Self.fullHistoryKey)
                defaults.set(true, forKey: Self.co2BackfillKey)
            }
            let backfilled = defaults.bool(forKey: Self.fullHistoryKey)
            let earliest = backfilled ? nil : try await health.earliestHistoryDate()
            let daysBack = Self.daysBack(backfilled: backfilled,
                                         earliest: earliest,
                                         now: now,
                                         calendar: cal)
            // The HealthKit queries are independent — run them concurrently while
            // keeping the @MainActor-isolated `health` on the main actor.
            let stepsTask = Task { @MainActor in try await health.dailySteps(daysBack: daysBack) }
            let walkRunTask = Task { @MainActor in try await health.dailyWalkRunDistance(daysBack: daysBack) }
            let workoutsTask = Task { @MainActor in try await health.workouts(daysBack: daysBack) }
            let steps = try await stepsTask.value
            let walkRunDistance = try await walkRunTask.value
            let hkWorkouts = try await workoutsTask.value

            let metrics = metricsProvider()

            // Cache external workouts for the UI (ours are already cached at record time).
            for w in hkWorkouts where !w.isFromThisApp {
                let estKcal = workoutCalories(type: w.type, distanceMeters: w.distanceMeters,
                                              movingSeconds: w.movingSeconds, metrics: metrics)
                let kcal = w.activeEnergyKcal ?? estKcal
                let co2 = w.co2SavedGrams
                    ?? CO2Estimator.avoidedGrams(type: w.type, distanceMeters: w.distanceMeters)
                try store.upsertWorkout(id: w.id, type: w.type, start: w.start,
                                        end: w.end, movingSeconds: w.movingSeconds,
                                        distanceMeters: w.distanceMeters,
                                        distanceEstimated: w.distanceEstimated,
                                        points: PointsEngine.workoutPoints(type: w.type,
                                                                           distanceMeters: w.distanceMeters),
                                        routeData: nil, splitSeconds: [],
                                        source: "external", hkSynced: true,
                                        calories: kcal,
                                        caloriesFromHealth: w.activeEnergyKcal != nil,
                                        co2SavedGrams: co2,
                                        co2FromHealth: w.co2SavedGrams != nil)
            }

            // Day inputs: HK workouts + local workouts that never reached HK.
            var workoutsByDay = HealthMappers.groupByDay(hkWorkouts, calendar: cal)
            var energyByDay: [Date: [WorkoutEnergyInput]] = [:]
            for w in hkWorkouts {
                let day = cal.startOfDay(for: w.start)
                energyByDay[day, default: []].append(
                    WorkoutEnergyInput(type: w.type, distanceMeters: w.distanceMeters,
                                       movingSeconds: w.movingSeconds, realKcal: w.activeEnergyKcal))
            }
            for rec in try store.pendingSync() {
                let day = cal.startOfDay(for: rec.start)
                workoutsByDay[day, default: []]
                    .append(WorkoutSummary(type: rec.type, distanceMeters: rec.distanceMeters))
                energyByDay[day, default: []].append(
                    WorkoutEnergyInput(type: rec.type, distanceMeters: rec.distanceMeters, movingSeconds: rec.movingSeconds))
            }

            let (windowStart, _) = HealthMappers.window(daysBack: daysBack,
                                                        endingAt: now, calendar: cal)
            var days: [DayActivity] = []
            for offset in 0..<daysBack {
                let date = cal.date(byAdding: .day, value: offset, to: windowStart)!
                guard date <= now else { break }
                days.append(DayActivity(date: date,
                                        steps: steps[date] ?? 0,
                                        workouts: workoutsByDay[date] ?? []))
            }

            // Derived, per-day: calories (de-duplicated) + total distance + active time.
            var derived: [Date: DayDerived] = [:]
            for day in days {
                let inputs = energyByDay[day.date] ?? []
                let kcal = CalorieEngine.dayCalories(steps: day.steps, workouts: inputs, metrics: metrics)?.total ?? 0
                let meters = inputs.reduce(0.0) { $0 + $1.distanceMeters }
                    + (walkRunDistance[day.date] ?? 0)
                let seconds = inputs.reduce(0.0) { $0 + $1.movingSeconds }
                derived[day.date] = DayDerived(activeCalories: kcal, distanceMeters: meters, activeSeconds: seconds)
            }

            let initialStreak = try store.latestLedger(before: windowStart)?.streakAfter ?? 0
            let ledgers = LedgerBuilder.build(days: days,
                                              goalProvider: store.goalProvider(currentGoal: currentGoal(),
                                                                               from: windowStart),
                                              initialStreak: initialStreak)
            try store.upsert(ledgers, derived: derived)
            // Only "spend" the one-shot backfill once it has actually run against real
            // HealthKit history. If `earliest` was nil — access not yet effective, or the
            // observer fired a sync before authorization on first launch — leave the flag
            // unset so a later sync performs the true full import instead of capping us at
            // the rolling window forever.
            if !backfilled && earliest != nil {
                defaults.set(true, forKey: Self.fullHistoryKey)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func retryPendingSaves() async {
        guard let pending = try? store.pendingSync(), !pending.isEmpty else { return }
        for rec in pending {
            let workout = RecordedWorkout(type: rec.type, start: rec.start, end: rec.end,
                                          movingSeconds: rec.movingSeconds,
                                          distanceMeters: rec.distanceMeters,
                                          route: rec.routeData.map { [RoutePoint].decode($0) } ?? [],
                                          splitSeconds: rec.splitSeconds)
            do {
                _ = try await health.saveWorkout(workout, points: rec.points)
                try store.upsertWorkout(id: rec.id, type: rec.type, start: rec.start, end: rec.end,
                                        movingSeconds: rec.movingSeconds,
                                        distanceMeters: rec.distanceMeters,
                                        distanceEstimated: rec.distanceEstimated, points: rec.points,
                                        routeData: rec.routeData, splitSeconds: rec.splitSeconds,
                                        source: rec.source, hkSynced: true, calories: rec.calories)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Workout calories from the given body metrics, or 0 when weight is unknown.
    private func workoutCalories(type: ActivityType, distanceMeters: Double,
                                 movingSeconds: Double, metrics: BodyMetrics) -> Double {
        guard let weightKg = metrics.weightKg else { return 0 }
        return CalorieEngine.workoutCalories(type: type, distanceMeters: distanceMeters,
                                             movingSeconds: movingSeconds, weightKg: weightKg)
    }
}
