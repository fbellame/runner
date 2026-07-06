import Foundation

@MainActor
final class SyncCoordinator {
    static let windowDays = 90

    private let health: HealthStoring
    private let store: DataStore
    private let currentGoal: () -> Int

    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false

    init(health: HealthStoring, store: DataStore, currentGoal: @escaping () -> Int) {
        self.health = health
        self.store = store
        self.currentGoal = currentGoal
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        // Snapshot once, before retrying: even a save that succeeds in this same
        // pass isn't guaranteed to be reflected by the HealthKit read below, so
        // these still count as "not in HK yet" for today's day-input build.
        let pendingBeforeRetry = (try? store.pendingSync()) ?? []
        await retryPendingSaves(pendingBeforeRetry)

        do {
            let cal = Calendar.current
            let steps = try await health.dailySteps(daysBack: Self.windowDays)
            let hkWorkouts = try await health.workouts(daysBack: Self.windowDays)

            // Cache external workouts for the UI (ours are already cached at record time).
            for w in hkWorkouts where !w.isFromThisApp {
                try store.upsertWorkout(id: w.id, type: w.type, start: w.start,
                                        end: w.start, movingSeconds: 0,
                                        distanceMeters: w.distanceMeters,
                                        points: PointsEngine.workoutPoints(type: w.type,
                                                                           distanceMeters: w.distanceMeters),
                                        routeData: nil, splitSeconds: [],
                                        source: "external", hkSynced: true)
            }

            // Day inputs: HK workouts + local workouts that weren't (or might not yet
            // be reflected as) in HK when we read it above.
            var workoutsByDay = HealthMappers.groupByDay(hkWorkouts, calendar: cal)
            for rec in pendingBeforeRetry {
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
                                              goalProvider: store.goalProvider(currentGoal: currentGoal()),
                                              initialStreak: initialStreak)
            try store.upsert(ledgers)
            lastSyncAt = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func retryPendingSaves(_ pending: [WorkoutRec]) async {
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
