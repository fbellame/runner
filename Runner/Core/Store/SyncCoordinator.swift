import Foundation

@MainActor
final class SyncCoordinator {
    static let windowDays = 90

    private let health: HealthStoring
    private let store: DataStore
    private let currentGoal: () -> Int

    private(set) var lastError: String?
    private(set) var isSyncing = false
    private var rerunRequested = false
    private var isSavingRecorded = false

    init(health: HealthStoring, store: DataStore, currentGoal: @escaping () -> Int) {
        self.health = health
        self.store = store
        self.currentGoal = currentGoal
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
        let routeData = try? workout.route.encoded()
        let id = UUID()
        try? store.upsertWorkout(id: id, type: workout.type, start: workout.start,
                                 end: workout.end, movingSeconds: workout.movingSeconds,
                                 distanceMeters: workout.distanceMeters, points: points,
                                 routeData: routeData, splitSeconds: workout.splitSeconds,
                                 source: "runner", hkSynced: false)
        var failure: String?
        do {
            _ = try await health.saveWorkout(workout, points: points)
            try? store.upsertWorkout(id: id, type: workout.type, start: workout.start,
                                     end: workout.end, movingSeconds: workout.movingSeconds,
                                     distanceMeters: workout.distanceMeters, points: points,
                                     routeData: routeData, splitSeconds: workout.splitSeconds,
                                     source: "runner", hkSynced: true)
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
            // The two HealthKit queries are independent — run them concurrently while
            // keeping the @MainActor-isolated `health` on the main actor.
            let stepsTask = Task { @MainActor in try await health.dailySteps(daysBack: Self.windowDays) }
            let workoutsTask = Task { @MainActor in try await health.workouts(daysBack: Self.windowDays) }
            let steps = try await stepsTask.value
            let hkWorkouts = try await workoutsTask.value

            // Cache external workouts for the UI (ours are already cached at record time).
            for w in hkWorkouts where !w.isFromThisApp {
                try store.upsertWorkout(id: w.id, type: w.type, start: w.start,
                                        end: w.end, movingSeconds: w.movingSeconds,
                                        distanceMeters: w.distanceMeters,
                                        points: PointsEngine.workoutPoints(type: w.type,
                                                                           distanceMeters: w.distanceMeters),
                                        routeData: nil, splitSeconds: [],
                                        source: "external", hkSynced: true)
            }

            // Day inputs: HK workouts + local workouts that never reached HK.
            var workoutsByDay = HealthMappers.groupByDay(hkWorkouts, calendar: cal)
            for rec in try store.pendingSync() {
                let day = cal.startOfDay(for: rec.start)
                workoutsByDay[day, default: []]
                    .append(WorkoutSummary(type: rec.type, distanceMeters: rec.distanceMeters))
            }

            let (windowStart, _) = HealthMappers.window(daysBack: Self.windowDays,
                                                        endingAt: Date(), calendar: cal)
            var days: [DayActivity] = []
            for offset in 0..<Self.windowDays {
                let date = cal.date(byAdding: .day, value: offset, to: windowStart)!
                guard date <= Date() else { break }
                days.append(DayActivity(date: date,
                                        steps: steps[date] ?? 0,
                                        workouts: workoutsByDay[date] ?? []))
            }

            let initialStreak = try store.latestLedger(before: windowStart)?.streakAfter ?? 0
            let ledgers = LedgerBuilder.build(days: days,
                                              goalProvider: store.goalProvider(currentGoal: currentGoal(),
                                                                               from: windowStart),
                                              initialStreak: initialStreak)
            try store.upsert(ledgers)
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
                                        distanceMeters: rec.distanceMeters, points: rec.points,
                                        routeData: rec.routeData, splitSeconds: rec.splitSeconds,
                                        source: rec.source, hkSynced: true)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
