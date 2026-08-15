import Testing
import Foundation
@testable import Runner

@MainActor
struct SyncCoordinatorTests {
    private func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: .now))!
    }

    private func freshDefaults() -> UserDefaults {
        let name = "SyncCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func make(goal: Int = 100,
                      metrics: BodyMetrics = BodyMetrics(weightKg: nil, heightCm: nil,
                                                         sex: .unspecified, age: nil),
                      defaults: UserDefaults? = nil)
        throws -> (SyncCoordinator, FakeHealthStore, DataStore) {
        let health = FakeHealthStore()
        let store = try DataStore(inMemory: true)
        let defaults = defaults ?? freshDefaults()
        let sync = SyncCoordinator(health: health, store: store, currentGoal: { goal },
                                   currentWeeklyTarget: { 3 },
                                   metricsProvider: { metrics }, defaults: defaults)
        return (sync, health, store)
    }

    @Test func daysBackUsesRollingWindowAfterBackfill() {
        #expect(SyncCoordinator.daysBack(backfilled: true, earliest: day(-365),
                                        now: day(0), calendar: .current) == 90)
    }

    @Test func daysBackUsesInclusiveEarliestSpanBeforeBackfill() {
        #expect(SyncCoordinator.daysBack(backfilled: false, earliest: day(-120),
                                        now: day(0), calendar: .current) == 121)
    }

    @Test func daysBackFallsBackToRollingWindowWhenEarliestIsNil() {
        #expect(SyncCoordinator.daysBack(backfilled: false, earliest: nil,
                                        now: day(0), calendar: .current) == 90)
    }

    @Test func daysBackFloorsRecentHistoryToRollingWindow() {
        #expect(SyncCoordinator.daysBack(backfilled: false, earliest: day(-12),
                                        now: day(0), calendar: .current) == 90)
    }

    @Test func syncFillsDerivedCalorieFields() async throws {
        let (sync, health, store) = try make(metrics: BodyMetrics(weightKg: 70, heightCm: 180,
                                                                  sex: .male, age: 30))
        let today = day(0)
        health.stepsByDay = [today: 10_000]
        health.cannedWorkouts = [ExternalWorkout(id: UUID(), type: .run,
                                                 start: today.addingTimeInterval(3600),
                                                 end: today.addingTimeInterval(5400),
                                                 movingSeconds: 1800, distanceMeters: 5000,
                                                 isFromThisApp: false)]
        await sync.syncNow()

        let row = try store.ledger(on: today)
        #expect((row?.activeCalories ?? 0) > 300)   // run + everyday steps
        #expect(row?.distanceMeters == 5000)
        #expect(row?.activeSeconds == 1800)
    }

    @Test func syncStoresEstimatedBikeDistanceAndAwardsPoints() async throws {
        let (sync, health, store) = try make()
        let today = day(0)
        let start = today.addingTimeInterval(9 * 3600)
        let estimatedMeters = try #require(WorkoutEstimation.estimatedMeters(type: .bike,
                                                                             movingSeconds: 1_800))
        let id = UUID()
        health.stepsByDay = [today: 1_000]
        health.cannedWorkouts = [
            ExternalWorkout(id: id, type: .bike,
                            start: start,
                            end: start.addingTimeInterval(1_800),
                            movingSeconds: 1_800,
                            distanceMeters: estimatedMeters,
                            distanceEstimated: true,
                            isFromThisApp: false)
        ]

        await sync.syncNow()

        let cached = try #require(try store.workouts(onDay: today).first)
        #expect(cached.id == id)
        #expect(cached.distanceMeters == estimatedMeters)
        #expect(cached.distanceEstimated)
        #expect(cached.points == 45)
        #expect(try store.ledger(on: today)?.workoutPoints == 45)
    }

    @Test func syncAddsAmbientWalkRunDistanceToDerivedLedgerDistanceOnly() async throws {
        let (sync, health, store) = try make()
        let today = day(0)
        let start = today.addingTimeInterval(9 * 3600)
        health.stepsByDay = [today: 1_000]
        health.walkRunByDay = [today: 2_400]
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .bike,
                            start: start,
                            end: start.addingTimeInterval(1_800),
                            movingSeconds: 1_800,
                            distanceMeters: 7_500,
                            distanceEstimated: true,
                            isFromThisApp: false)
        ]

        await sync.syncNow()

        let row = try store.ledger(on: today)
        #expect(row?.distanceMeters == 9_900)
        #expect(row?.workoutPoints == 45)
        #expect(row?.totalPoints == 55)
        #expect(health.dailyWalkRunDistanceDaysBack == [90])
    }

    @Test func backfillBuildsLedgersWithStreaks() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(-2): 12_000, day(-1): 3_000, day(0): 8_450]
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .run,
                            start: day(0).addingTimeInterval(9 * 3600),
                            end: day(0).addingTimeInterval(9 * 3600 + 720),
                            movingSeconds: 700,
                            distanceMeters: 2_100, isFromThisApp: false)
        ]
        await sync.syncNow()
        #expect(sync.lastError == nil)
        // day -2: 120 pts gold; day -1: 30 pts not gold; day 0: (84+32)×1.0 = 116 gold
        #expect(try store.ledger(on: day(-2))?.totalPoints == 120)
        #expect(try store.ledger(on: day(-1))?.isGold == false)
        let today = try store.ledger(on: day(0))
        #expect(today?.totalPoints == 116)
        #expect(today?.isGold == true)
        #expect(today?.streakAfter == 1)
        // external workout cached for UI
        let cached = try store.workouts(onDay: day(0))
        #expect(cached.count == 1)
        #expect(cached[0].source == "external")
        #expect(cached[0].points == 32)
    }

    @Test func pendingWorkoutSyncsAndCountsToday() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        // a locally recorded, not-yet-synced run
        try store.upsertWorkout(id: UUID(), type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                movingSeconds: 1500, distanceMeters: 5_000, points: 75,
                                routeData: try [RoutePoint(lat: 45.5, lon: -73.6, t: .now, afterGap: false),
                                                RoutePoint(lat: 45.51, lon: -73.6, t: .now, afterGap: false)].encoded(),
                                splitSeconds: [300, 300, 300, 300, 300],
                                source: "runner", hkSynced: false)
        await sync.syncNow()
        #expect(health.savedWorkouts.count == 1)
        #expect(health.savedWorkouts[0].1 == 75)
        #expect(try store.pendingSync().isEmpty)
        // today's ledger includes the pending workout: 10 + 75 = 85
        #expect(try store.ledger(on: day(0))?.totalPoints == 85)
    }

    @Test func failedHealthSaveKeepsPendingAndContinues() async throws {
        let (sync, health, store) = try make()
        health.saveError = NSError(domain: "HK", code: 5,
                                   userInfo: [NSLocalizedDescriptionKey: "not authorized"])
        health.stepsByDay = [day(0): 10_000]
        try store.upsertWorkout(id: UUID(), type: .bike, start: day(0).addingTimeInterval(3600),
                                end: day(0).addingTimeInterval(5400),
                                movingSeconds: 1800, distanceMeters: 10_000, points: 60,
                                routeData: nil, splitSeconds: [],
                                source: "runner", hkSynced: false)
        await sync.syncNow()
        #expect(try store.pendingSync().count == 1)      // still pending
        #expect(sync.lastError != nil)
        // ledger still computed: 100 steps pts + 60 bike = 160
        #expect(try store.ledger(on: day(0))?.totalPoints == 160)
    }

    @Test func externalWorkoutKeepsDuration() async throws {
        let (sync, health, store) = try make()
        let start = day(0).addingTimeInterval(9 * 3600)
        health.stepsByDay = [day(0): 1_000]
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .run, start: start,
                            end: start.addingTimeInterval(2_700), movingSeconds: 2_640,
                            distanceMeters: 8_000, isFromThisApp: false)
        ]
        await sync.syncNow()
        let cached = try #require(try store.workouts(onDay: day(0)).first)
        #expect(cached.end == start.addingTimeInterval(2_700))   // real end, not start
        #expect(cached.movingSeconds == 2_640)                   // real duration, not 0
    }

    @Test func syncRequestedMidSyncRunsAgain() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        var reentered = false
        health.workoutsHook = { [weak sync, weak health] in
            guard let sync, let health, !reentered else { return }
            reentered = true
            // New data lands while the first sync is mid-flight; the request
            // must be queued as a trailing rerun, not silently dropped.
            health.stepsByDay = [self.day(0): 5_000]
            await sync.syncNow()
        }
        await sync.syncNow()
        #expect(reentered)
        #expect(try store.ledger(on: day(0))?.totalPoints == 50) // rerun picked up 5 000 steps
    }

    @Test func saveRecordedPersistsLocallyBeforeHealthKit() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        let workout = RecordedWorkout(type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                      end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                      movingSeconds: 1500, distanceMeters: 5_000,
                                      route: [], splitSeconds: [300, 300, 300, 300, 300])
        var pendingAtHKSaveTime = -1
        health.saveHook = {
            pendingAtHKSaveTime = (try? store.pendingSync().count) ?? -1
        }
        let outcome = await sync.saveRecorded(workout)
        #expect(outcome == .saved)
        #expect(pendingAtHKSaveTime == 1)   // durable locally before HealthKit ran
        let all = try store.allWorkouts()
        #expect(all.count == 1)             // one record, marked synced afterwards
        #expect(all[0].hkSynced == true)
        // counted exactly once in the ledger: 10 step pts + 75 workout pts
        #expect(try store.ledger(on: day(0))?.totalPoints == 85)
    }

    @Test func saveRecordedKeepsStableIdAcrossFailureAndRetry() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        health.saveError = NSError(domain: "HK", code: 5,
                                   userInfo: [NSLocalizedDescriptionKey: "refused"])
        let workout = RecordedWorkout(type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                      end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                      movingSeconds: 1500, distanceMeters: 5_000,
                                      route: [], splitSeconds: [])
        let outcome = await sync.saveRecorded(workout)
        #expect(outcome.healthKitFailure != nil)
        #expect(outcome.isLocallyDurable)
        let id = try #require(try store.allWorkouts().first?.id)
        #expect(try store.pendingSync().count == 1)
        // HealthKit recovers; the retry syncs the SAME record, no duplicate
        health.saveError = nil
        await sync.syncNow()
        let all = try store.allWorkouts()
        #expect(all.count == 1)
        #expect(all[0].id == id)
        #expect(all[0].hkSynced == true)
        #expect(try store.ledger(on: day(0))?.totalPoints == 85)
    }

    @Test func saveRecordedIgnoresReentrantDuplicate() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        let workout = RecordedWorkout(type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                      end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                      movingSeconds: 1500, distanceMeters: 5_000,
                                      route: [], splitSeconds: [])
        health.saveHook = { [weak sync, weak health] in
            // A second tap on Save while the first is in flight must be a no-op.
            health?.saveHook = nil
            await sync?.saveRecorded(workout)
        }
        await sync.saveRecorded(workout)
        #expect(health.savedWorkouts.count == 1)
        #expect(try store.allWorkouts().count == 1)
        #expect(try store.ledger(on: day(0))?.totalPoints == 85)
    }

    /// CRITICAL 4 regression: the overlap guard used to `return nil` — which is
    /// this function's SUCCESS value — for any call landing while another save
    /// was in flight, including one for a completely different workout. The
    /// caller then cleared the recovery checkpoint and spoke "Run saved" for a
    /// workout that was never written anywhere.
    @Test func concurrentDistinctSavesAreBothPersisted() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        let first = RecordedWorkout(type: .run, start: day(0).addingTimeInterval(8 * 3600),
                                    end: day(0).addingTimeInterval(8 * 3600 + 1500),
                                    movingSeconds: 1500, distanceMeters: 5_000,
                                    route: [], splitSeconds: [])
        let second = RecordedWorkout(type: .run, start: day(0).addingTimeInterval(12 * 3600),
                                     end: day(0).addingTimeInterval(12 * 3600 + 900),
                                     movingSeconds: 900, distanceMeters: 3_000,
                                     route: [], splitSeconds: [])
        health.saveHook = { [weak sync, weak health] in
            health?.saveHook = nil
            await sync?.saveRecorded(second)
        }

        await sync.saveRecorded(first)

        #expect(try store.allWorkouts().count == 2)
        #expect(health.savedWorkouts.count == 2)
    }

    /// CRITICAL 3 regression: the overlap guard used full `RecordedWorkout`
    /// value equality, but the persistent store's identity is `(type, start)`.
    /// Two representations of the same session — a live finish and a recovery
    /// "Save as-is", whose `end` can legitimately differ — are NOT value-equal,
    /// so both used to sail past the guard and each independently push the
    /// workout to HealthKit.
    @Test func concurrentSaveOfTheSameSessionWithADifferentEndIsNotPushedTwice() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        let start = day(0).addingTimeInterval(8 * 3600)
        let liveFinish = RecordedWorkout(type: .run, start: start,
                                         end: start.addingTimeInterval(1_500),
                                         movingSeconds: 1_500, distanceMeters: 5_000,
                                         route: [], splitSeconds: [])
        // Same session (same type + start), recovered via "Save as-is": the
        // checkpoint's `savedAt` becomes `end`, which differs from the live
        // finish's real GPS-derived end — exactly CRITICAL 3's scenario.
        let recovered = RecordedWorkout(type: .run, start: start,
                                        end: start.addingTimeInterval(1_490),
                                        movingSeconds: 1_490, distanceMeters: 4_950,
                                        route: [], splitSeconds: [])
        health.saveHook = { [weak sync, weak health] in
            health?.saveHook = nil
            await sync?.saveRecorded(recovered)
        }

        let outcome = await sync.saveRecorded(liveFinish)

        #expect(outcome == .saved)
        #expect(health.savedWorkouts.count == 1)      // pushed to HealthKit once, not twice
        #expect(try store.allWorkouts().count == 1)
    }

    /// IMPORTANT 6 regression: a checkpoint written by a pre-upgrade build
    /// corresponds to a workout row (if it was ever saved) under a random
    /// UUID, since recovery saves didn't use a deterministic id yet.
    /// Recovering it now must reconcile onto that existing row rather than
    /// create a second one — and re-push to HealthKit — under the new
    /// deterministic id.
    @Test func recoveringALegacyCheckpointReconcilesOntoItsPreUpgradeRow() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        let start = day(0).addingTimeInterval(8 * 3600)
        let legacyID = UUID()   // pre-upgrade: random, not the deterministic id
        try store.upsertWorkout(id: legacyID, type: .run, start: start,
                                end: start.addingTimeInterval(1_500),
                                movingSeconds: 1_500, distanceMeters: 5_000, points: 75,
                                routeData: nil, splitSeconds: [],
                                source: "runner", hkSynced: true)

        let workout = RecordedWorkout(type: .run, start: start,
                                      end: start.addingTimeInterval(1_500),
                                      movingSeconds: 1_500, distanceMeters: 5_000,
                                      route: [], splitSeconds: [])
        let outcome = await sync.saveRecorded(workout)

        #expect(outcome == .saved)
        let all = try store.allWorkouts()
        #expect(all.count == 1)                 // reconciled, not duplicated
        #expect(all.first?.id == legacyID)
        #expect(health.savedWorkouts.isEmpty)    // already in Health; not re-pushed
    }

    /// CRITICAL 2 (wave 3) regression: `saveRecorded` guards concurrency by the
    /// deterministic id `D`, but when it reconciles onto a legacy random-UUID
    /// row `L` it awaits HealthKit under `L`, not `D`. `retryPendingSaves()`
    /// used to filter pending rows by `rec.id` (i.e. `L`), which was never in
    /// `savesInFlight` — a concurrent `syncNow()` landing inside that
    /// HealthKit await saw the legacy row as un-guarded and pushed it to
    /// Health a second time. The existing I6 test above only covers
    /// `hkSynced == true` (no HealthKit call happens at all in that case),
    /// which is why this slipped through.
    @Test func concurrentSyncDuringLegacyReconciliationPushesLegacyRowOnce() async throws {
        let (sync, health, store) = try make()
        health.stepsByDay = [day(0): 1_000]
        let start = day(0).addingTimeInterval(8 * 3600)
        let legacyID = UUID()   // pre-upgrade: random, not the deterministic id
        try store.upsertWorkout(id: legacyID, type: .run, start: start,
                                end: start.addingTimeInterval(1_500),
                                movingSeconds: 1_500, distanceMeters: 5_000, points: 75,
                                routeData: nil, splitSeconds: [],
                                source: "runner", hkSynced: false)

        let workout = RecordedWorkout(type: .run, start: start,
                                      end: start.addingTimeInterval(1_500),
                                      movingSeconds: 1_500, distanceMeters: 5_000,
                                      route: [], splitSeconds: [])
        // A distinct, unrelated session — its own saveRecorded's trailing
        // syncNow() (-> retryPendingSaves()) is what surfaces the bug, by
        // running concurrently with the legacy row's HealthKit await.
        let distinct = RecordedWorkout(type: .run, start: day(0).addingTimeInterval(12 * 3600),
                                       end: day(0).addingTimeInterval(12 * 3600 + 900),
                                       movingSeconds: 900, distanceMeters: 3_000,
                                       route: [], splitSeconds: [])
        health.saveHook = { [weak sync, weak health] in
            health?.saveHook = nil
            await sync?.saveRecorded(distinct)
        }

        let outcome = await sync.saveRecorded(workout)

        #expect(outcome == .saved)
        #expect(try store.allWorkouts().count == 2)     // legacy row + distinct, no duplicate row
        // Exactly one HealthKit push for the legacy session.
        #expect(health.savedWorkouts.filter { $0.0.start == start }.count == 1)
    }

    @Test func storedGoalsPreservedOnResync() async throws {
        let (sync, health, store) = try make(goal: 150)
        // Yesterday was finalized under goal 70.
        try store.upsert([LedgerDay(date: day(-1), steps: 8_000,
                                    breakdown: PointsBreakdown(stepPoints: 80, workoutPoints: 0,
                                                               multiplier: 1.0, total: 80),
                                    goal: 70, weeklyTarget: 3, isGold: true, streakAfter: 1)])
        health.stepsByDay = [day(-1): 8_000, day(0): 8_000]
        await sync.syncNow()
        let yesterday = try store.ledger(on: day(-1))
        #expect(yesterday?.goalAtThatTime == 70)
        #expect(yesterday?.isGold == true)               // 80 ≥ 70 under its own goal
        #expect(try store.ledger(on: day(0))?.goalAtThatTime == 150)
    }

    @Test func firstSyncBackfillsFromEarliestHistoryDateAndSetsFlag() async throws {
        let defaults = freshDefaults()
        let (sync, health, store) = try make(defaults: defaults)
        let earliest = day(-120)
        let workoutID = UUID()
        health.earliestHistoryDateStub = earliest
        health.stepsByDay = [earliest: 12_000]
        health.cannedWorkouts = [
            ExternalWorkout(id: workoutID, type: .run,
                            start: earliest.addingTimeInterval(8 * 3600),
                            end: earliest.addingTimeInterval(8 * 3600 + 1_500),
                            movingSeconds: 1_500,
                            distanceMeters: 5_000,
                            isFromThisApp: false)
        ]

        await sync.syncNow()

        #expect(sync.lastError == nil)
        #expect(health.earliestHistoryDateCalls == 1)
        #expect(health.dailyStepsDaysBack == [121])
        #expect(health.dailyWalkRunDistanceDaysBack == [121])
        #expect(health.workoutsDaysBack == [121])
        #expect(defaults.bool(forKey: "fullHistoryBackfilled"))
        #expect(try store.workouts(onDay: earliest).first?.id == workoutID)
        #expect(try store.ledger(on: earliest)?.steps == 12_000)
    }

    @Test func secondSyncAfterBackfillUsesRollingWindow() async throws {
        let defaults = freshDefaults()
        let (sync, health, _) = try make(defaults: defaults)
        health.earliestHistoryDateStub = day(-120)

        await sync.syncNow()
        await sync.syncNow()

        #expect(sync.lastError == nil)
        #expect(health.earliestHistoryDateCalls == 1)
        #expect(health.dailyStepsDaysBack == [121, 90])
        #expect(health.dailyWalkRunDistanceDaysBack == [121, 90])
        #expect(health.workoutsDaysBack == [121, 90])
        #expect(defaults.bool(forKey: "fullHistoryBackfilled"))
    }

    @Test func failingFirstBackfillPassLeavesFlagUnset() async throws {
        let defaults = freshDefaults()
        let (sync, health, _) = try make(defaults: defaults)
        health.earliestHistoryDateStub = day(-120)
        health.dailyStepsError = NSError(domain: "HK", code: 7,
                                         userInfo: [NSLocalizedDescriptionKey: "step read failed"])

        await sync.syncNow()

        #expect(sync.lastError == "step read failed")
        #expect(health.earliestHistoryDateCalls == 1)
        #expect(defaults.bool(forKey: "fullHistoryBackfilled") == false)
    }

    @Test func nilEarliestDoesNotConsumeBackfillAndLaterSyncStillImportsHistory() async throws {
        let defaults = freshDefaults()
        let (sync, health, _) = try make(defaults: defaults)

        // First launch: HealthKit not yet readable (e.g. observer-triggered sync
        // racing authorization) — earliest is nil, so the one-shot must NOT be spent.
        health.earliestHistoryDateStub = nil
        await sync.syncNow()

        #expect(sync.lastError == nil)
        #expect(health.dailyWalkRunDistanceDaysBack == [90])
        #expect(health.workoutsDaysBack == [90])
        #expect(defaults.bool(forKey: "fullHistoryBackfilled") == false)

        // Later sync, once history is readable: performs the true full backfill.
        health.earliestHistoryDateStub = day(-120)
        await sync.syncNow()

        #expect(health.dailyWalkRunDistanceDaysBack == [90, 121])
        #expect(health.workoutsDaysBack == [90, 121])
        #expect(defaults.bool(forKey: "fullHistoryBackfilled"))
    }

    @Test func v14UpgradeForcesOneTimeFullReimportThenRolls() async throws {
        let defaults = freshDefaults()
        // Simulate a store already backfilled under v1.3.
        defaults.set(true, forKey: "fullHistoryBackfilled")
        let (sync, health, _) = try make(defaults: defaults)
        health.earliestHistoryDateStub = day(-120)

        await sync.syncNow()
        // Despite the pre-set v1.3 flag, v1.4's first sync re-imports full history…
        #expect(health.workoutsDaysBack == [121])
        #expect(defaults.bool(forKey: "v14MetricsBackfilled"))

        // …and the next sync returns to the rolling window (one-time only).
        await sync.syncNow()
        #expect(health.workoutsDaysBack == [121, 90])
    }

    @Test func externalWorkoutUsesRealHealthCaloriesAndCo2() async throws {
        let (sync, health, store) = try make(metrics: BodyMetrics(weightKg: 70, heightCm: 175,
                                                                  sex: .male, age: 30))
        let now = day(0)
        health.earliestHistoryDateStub = now
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .bike, start: now, end: now,
                            movingSeconds: 1200, distanceMeters: 5000,
                            activeEnergyKcal: 130, co2SavedGrams: 900,
                            isFromThisApp: false)
        ]
        await sync.syncNow()

        let rec = try #require(try store.allWorkouts().first)
        #expect(rec.calories == 130)
        #expect(rec.caloriesFromHealth == true)
        #expect(rec.co2SavedGrams == 900)
        #expect(rec.co2FromHealth == true)
    }

    @Test func externalWorkoutFallsBackToEstimatesWhenHealthHasNone() async throws {
        let (sync, health, store) = try make(metrics: BodyMetrics(weightKg: 70, heightCm: 175,
                                                                  sex: .male, age: 30))
        let now = day(0)
        health.earliestHistoryDateStub = now
        health.cannedWorkouts = [
            ExternalWorkout(id: UUID(), type: .bike, start: now, end: now,
                            movingSeconds: 1200, distanceMeters: 5000,
                            activeEnergyKcal: nil, co2SavedGrams: nil,
                            isFromThisApp: false)
        ]
        await sync.syncNow()

        let rec = try #require(try store.allWorkouts().first)
        #expect(rec.caloriesFromHealth == false)
        #expect(rec.co2FromHealth == false)
        // 5 km bike → CO2Estimator computed value.
        #expect(abs(rec.co2SavedGrams - CO2Estimator.avoidedGrams(type: .bike, distanceMeters: 5000)) < 0.001)
    }
}
