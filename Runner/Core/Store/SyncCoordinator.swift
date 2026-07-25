import Foundation

/// What `SyncCoordinator.saveRecorded` actually did.
///
/// CRITICAL 4 + CRITICAL 5 fix. This replaces a `String?` return in which `nil`
/// meant BOTH "saved" and "dropped because another save was in flight", and in
/// which a failed *local* write was indistinguishable from a clean save because
/// `try?` swallowed it. Callers gate the two irreversible acts of the save path
/// — clearing the recovery checkpoint and speaking "Run saved" — on
/// `isLocallyDurable`, which is true only when the durable local copy really
/// exists.
enum RecordedSaveOutcome: Equatable, Sendable {
    /// Written locally and accepted by HealthKit.
    case saved
    /// Written locally; HealthKit refused. The run is safe — the local store is
    /// the durable copy and `retryPendingSaves` will push it later. Announcing
    /// success here is intentional and long-standing behaviour.
    case savedLocallyOnly(reason: String)
    /// The durable local write failed. The run exists nowhere: the caller must
    /// keep the recovery checkpoint and must NOT announce a save.
    case localFailed(reason: String)
    /// An identical workout was already being saved by another in-flight call,
    /// so this call did nothing. Not a success — the caller has learned nothing
    /// about whether the other call will land, so it must not clear the
    /// checkpoint or announce on the strength of this result.
    case duplicateInFlight

    /// True only when a durable local copy of the workout now exists.
    var isLocallyDurable: Bool {
        switch self {
        case .saved, .savedLocallyOnly: true
        case .localFailed, .duplicateInFlight: false
        }
    }

    /// The HealthKit-only failure message, for UI that reports a partial save.
    /// Preserves the old `String?` contract for the in-app save sheet.
    var healthKitFailure: String? {
        if case .savedLocallyOnly(let reason) = self { return reason }
        return nil
    }

    /// The message for a failure that means the run was NOT persisted.
    var durableFailure: String? {
        if case .localFailed(let reason) = self { return reason }
        return nil
    }
}

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
    private let currentWeeklyTarget: () -> Int
    private let metricsProvider: () -> BodyMetrics
    private let defaults: UserDefaults

    private(set) var lastError: String?
    private(set) var isSyncing = false
    private var rerunRequested = false
    /// CRITICAL 4 fix: the workouts whose saves are currently in flight, not a
    /// bare "a save is running" flag. The old flag dropped ANY overlapping call,
    /// including one for a completely different workout, and reported that drop
    /// as success. Identity is what the guard was always trying to express: a
    /// second tap on Save for the SAME run is a no-op; a second, distinct run is
    /// not, and must actually be written. Concurrent saves of distinct workouts
    /// are safe to run in parallel — they touch different rows (distinct ids)
    /// and `syncNow()` already carries its own re-entrancy guard — so distinct
    /// calls proceed rather than queue, which also keeps a nested save (one
    /// issued from inside another's HealthKit await) from deadlocking.
    ///
    /// CRITICAL 3 fix: keyed on `recordedWorkoutID(type:start:)` — the same
    /// identity the persistent store uses — rather than full `RecordedWorkout`
    /// value equality. Two representations of the same session (a live finish
    /// versus a recovery "Save as-is") can differ in fields like `end`, so
    /// value equality let both proceed and each independently push to
    /// HealthKit. `(type, start)` is "the same session" everywhere else in this
    /// file; the in-flight guard now means the same thing.
    private var savesInFlight: Set<UUID> = []

    init(health: HealthStoring, store: DataStore, currentGoal: @escaping () -> Int,
         currentWeeklyTarget: @escaping () -> Int,
         metricsProvider: @escaping () -> BodyMetrics, defaults: UserDefaults = .standard) {
        self.health = health
        self.store = store
        self.currentGoal = currentGoal
        self.currentWeeklyTarget = currentWeeklyTarget
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

    /// The local-store identity of a recorded workout.
    ///
    /// CRITICAL 3 support. "Write the workout" and "clear the recovery
    /// checkpoint" cannot be made one atomic step, so a kill between them leaves
    /// a checkpoint on disk for a run that is already saved. Under the previous
    /// `let id = UUID()`, the resume prompt's "Save as-is" would then write that
    /// run a SECOND time under a brand-new id — a duplicate workout. Deriving
    /// the id from the session's own identity turns that second write into an
    /// upsert over the same row instead.
    ///
    /// Identity is `(type, start)`: `startedAt` is assigned once per session and
    /// `RecordedWorkout` already treats `start` as its identity (see its
    /// `Identifiable` conformance). The checkpoint round-trips `startedAt`
    /// through JSON, so the instant is quantised to milliseconds rather than
    /// trusting the last bits of a `Double`. Two distinct recordings cannot
    /// share a type and a start millisecond, so this collides only where the two
    /// records genuinely describe the same session.
    static func recordedWorkoutID(type: ActivityType, start: Date) -> UUID {
        let millis = Int64((start.timeIntervalSince1970 * 1000).rounded())
        let key = "runner|\(type.rawValue)|\(millis)"
        // Two FNV-1a passes over differently-salted copies of the same key give
        // 128 stable bits without pulling in a hashing dependency. Swift's own
        // `hashValue` is per-process randomised and cannot be used here.
        var bytes: [UInt8] = []
        for salt in ["hi|", "lo|"] {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in Array((salt + key).utf8) {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: hash >> UInt64(shift)))
            }
        }
        // RFC 4122 version/variant bits, so the result is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Persists a freshly recorded workout: local store first (durable even if the
    /// app dies mid-save), then HealthKit, then mark synced under the same id —
    /// the one save path shared with retryPendingSaves.
    ///
    /// CRITICAL 5 fix: the local write's error is no longer swallowed by `try?`.
    /// It is the durable copy everything else relies on, so its failure is
    /// reported as `.localFailed` and HealthKit is not attempted at all — a
    /// half-save that reaches Health but has no local row would be re-pushed by
    /// `retryPendingSaves` on the next recovery attempt and duplicate there.
    /// The caller keeps its recovery checkpoint instead and can retry the whole
    /// thing. HealthKit-only failure keeps its long-standing meaning: the run is
    /// safe locally, so announcing the save is still correct.
    @discardableResult
    func saveRecorded(_ workout: RecordedWorkout) async -> RecordedSaveOutcome {
        let deterministicID = Self.recordedWorkoutID(type: workout.type, start: workout.start)
        guard !savesInFlight.contains(deterministicID) else { return .duplicateInFlight }
        savesInFlight.insert(deterministicID)
        defer { savesInFlight.remove(deterministicID) }

        let points = PointsEngine.workoutPoints(type: workout.type,
                                                distanceMeters: workout.distanceMeters)
        let kcal = workoutCalories(type: workout.type, distanceMeters: workout.distanceMeters,
                                   movingSeconds: workout.movingSeconds, metrics: metricsProvider())
        let routeData = try? workout.route.encoded()
        // IMPORTANT 6: a checkpoint written by a pre-upgrade build corresponds,
        // if it was ever saved at all, to a row under a random UUID — recovery
        // saves didn't use a deterministic id yet. Reconcile onto that existing
        // row (same `(type, start)`, different id) instead of creating a
        // duplicate under the new deterministic one. Cheap: one extra indexed
        // lookup, only on the recovery path where the deterministic id misses.
        let id = (try? store.workout(id: deterministicID)) != nil
            ? deterministicID
            : (try? store.workout(type: workout.type, start: workout.start))?.id ?? deterministicID
        // A re-save of a session that already reached HealthKit (the crash
        // window between the local write and `checkpoints.clear()`, recovered
        // via "Save as-is") must refresh the local row without pushing a second
        // copy into Health.
        let alreadyInHealth = (try? store.workout(id: id))?.hkSynced == true
        do {
            try store.upsertWorkout(id: id, type: workout.type, start: workout.start,
                                    end: workout.end, movingSeconds: workout.movingSeconds,
                                    distanceMeters: workout.distanceMeters,
                                    distanceEstimated: workout.distanceEstimated, points: points,
                                    routeData: routeData, splitSeconds: workout.splitSeconds,
                                    source: "runner", hkSynced: alreadyInHealth, calories: kcal,
                                    autoStarted: workout.autoStarted)
        } catch {
            // Surface it the same way a failed sync is surfaced (TodayView reads
            // `lastError`), and skip the `syncNow()` below that would clear it.
            lastError = error.localizedDescription
            return .localFailed(reason: error.localizedDescription)
        }
        var failure: String?
        if !alreadyInHealth {
            do {
                _ = try await health.saveWorkout(workout, points: points)
                try? store.upsertWorkout(id: id, type: workout.type, start: workout.start,
                                         end: workout.end, movingSeconds: workout.movingSeconds,
                                         distanceMeters: workout.distanceMeters,
                                         distanceEstimated: workout.distanceEstimated, points: points,
                                         routeData: routeData, splitSeconds: workout.splitSeconds,
                                         source: "runner", hkSynced: true, calories: kcal,
                                         autoStarted: workout.autoStarted)
            } catch {
                failure = error.localizedDescription
            }
        }
        await syncNow()
        return failure.map { .savedLocallyOnly(reason: $0) } ?? .saved
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
                                              weeklyTargetProvider: store.weeklyTargetProvider(currentTarget: currentWeeklyTarget(),
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
        // A workout whose own `saveRecorded` is between its local write and its
        // HealthKit await is already on its way to Health, and its local row is
        // legitimately still `hkSynced == false`. Pushing it again from here
        // would put a duplicate in Health. This only became reachable once
        // distinct saves were allowed to overlap (CRITICAL 4): a concurrent
        // save's trailing `syncNow()` can now land inside another save's
        // HealthKit await.
        for rec in pending where !savesInFlight.contains(rec.id) {
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
