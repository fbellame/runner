import Foundation
import Observation

enum AppTab {
    case today
    case history
    case routes
}

@MainActor
@Observable
final class AppModel {
    static let goalKey = "dailyGoal"
    static let profilePromptKey = "didShowProfilePrompt_v1_1"
    /// IMPORTANT 6: records that a celebration was dismissed, out-of-band from
    /// the file whose deletion may have failed. Holds the celebration's `start`
    /// as a Unix timestamp; see `clearPendingCelebration()`.
    static let acknowledgedCelebrationKey = "acknowledgedCelebrationStart"
    /// Single source for the allowed daily-goal bounds — the Settings stepper,
    /// the didSet clamp, and storedGoal() must never disagree.
    static let goalRange = 50...500

    static let weeklyTargetKey = "weeklyGoldTarget"
    /// Allowed weekly consistency target — gold days per week.
    static let weeklyTargetRange = 1...7

    static func weeklyDistanceGoalKey(for type: ActivityType) -> String {
        "weeklyDistanceGoal.\(type.rawValue)"
    }

    let store: DataStore
    let health: HealthStoring
    let sync: SyncCoordinator
    let recorder: WorkoutRecorder
    let checkpoints: CheckpointStore
    let profile: ProfileStore
    let pendingCelebrations: PendingCelebrationStore
    var pendingCelebration: RecordedWorkout?
    private(set) var autoWalk: AutoWalkCoordinator?

    var pendingResume: SessionCheckpoint?
    var showRecordSheet = false
    var selectedTab: AppTab = .today
    /// Set when the persistent store failed to open and the app is running on an
    /// in-memory fallback: everything recorded now is lost on relaunch, so the UI
    /// must say so instead of looking healthy.
    var storeFailureMessage: String?
    /// One-time invitation (first v1.1 launch) to review body metrics for calories.
    var showProfilePrompt = false

    @ObservationIgnored nonisolated(unsafe) private var dayChangeObserver: (any NSObjectProtocol)?

    /// The early `return` on the clamp path used to skip the persistence below
    /// it. Swift does not re-enter an observer for an assignment made inside that
    /// observer, so an out-of-range value was clamped in memory and never written
    /// — it reverted on the next launch. Clamp, then always persist whatever the
    /// property now holds.
    var dailyGoal: Int {
        didSet {
            let clamped = min(max(dailyGoal, Self.goalRange.lowerBound), Self.goalRange.upperBound)
            if clamped != dailyGoal { dailyGoal = clamped }
            UserDefaults.standard.set(dailyGoal, forKey: Self.goalKey)
            Task { await sync.syncNow() }
        }
    }

    /// Same clamp-then-persist shape as `dailyGoal`, for the same reason.
    var weeklyGoldTarget: Int {
        didSet {
            let clamped = min(max(weeklyGoldTarget, Self.weeklyTargetRange.lowerBound), Self.weeklyTargetRange.upperBound)
            if clamped != weeklyGoldTarget { weeklyGoldTarget = clamped }
            UserDefaults.standard.set(weeklyGoldTarget, forKey: Self.weeklyTargetKey)
            Task { await sync.syncNow() }
        }
    }

    private(set) var weeklyDistanceGoals: [ActivityType: Double]

    static func storedGoal() -> Int {
        let raw = UserDefaults.standard.object(forKey: goalKey) as? Int ?? 100
        return min(max(raw, goalRange.lowerBound), goalRange.upperBound)
    }

    static func storedWeeklyTarget() -> Int {
        let raw = UserDefaults.standard.object(forKey: weeklyTargetKey) as? Int ?? 3
        return min(max(raw, weeklyTargetRange.lowerBound), weeklyTargetRange.upperBound)
    }

    static func storedWeeklyDistanceGoal(for type: ActivityType) -> Double? {
        let key = weeklyDistanceGoalKey(for: type)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: key)
        return value.isFinite && value > 0 ? value : nil
    }

    func weeklyDistanceGoal(for type: ActivityType) -> Double? {
        weeklyDistanceGoals[type]
    }

    func setWeeklyDistanceGoal(_ kilometers: Double?, for type: ActivityType) {
        let key = Self.weeklyDistanceGoalKey(for: type)
        guard let kilometers, kilometers.isFinite, kilometers > 0 else {
            weeklyDistanceGoals.removeValue(forKey: type)
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        weeklyDistanceGoals[type] = kilometers
        UserDefaults.standard.set(kilometers, forKey: key)
    }

    init(store: DataStore,
         health: HealthStoring,
         recorder: WorkoutRecorder,
         checkpoints: CheckpointStore,
         pendingCelebrations: PendingCelebrationStore = PendingCelebrationStore()) {
        self.store = store
        self.health = health
        self.recorder = recorder
        self.checkpoints = checkpoints
        self.pendingCelebrations = pendingCelebrations
        self.dailyGoal = Self.storedGoal()
        self.weeklyGoldTarget = Self.storedWeeklyTarget()
        self.weeklyDistanceGoals = Dictionary(uniqueKeysWithValues:
            ActivityType.allCases.compactMap { type in
                Self.storedWeeklyDistanceGoal(for: type).map { (type, $0) }
            })
        let profile = ProfileStore(store: store, health: health)
        self.profile = profile
        self.sync = SyncCoordinator(health: health, store: store,
                                    currentGoal: { Self.storedGoal() },
                                    currentWeeklyTarget: { Self.storedWeeklyTarget() },
                                    metricsProvider: { profile.currentMetrics() })
    }

    /// True when no other owner already has the recorder: no unanswered resume
    /// prompt, no open record sheet, and the recorder itself is idle. Shared by
    /// auto-walk detection and the Start Run intent so neither can hijack a
    /// session the other (or the user) already owns.
    var canAutoStart: Bool {
        pendingResume == nil &&
        !showRecordSheet &&
        recorder.state == .idle
    }

    /// Entry point for the Lock Screen / Control Center `StartRunIntent`. Arms a
    /// run so its clock stays frozen until real movement, without unlocking or
    /// foregrounding the app.
    @discardableResult
    func startRunFromIntent(
        announcesStartOnMovement: Bool = true
    ) -> StartRunVoiceOutcome {
        // CRITICAL 1, the half that hoisting the load inside `onLaunch()` cannot
        // reach: a `LiveActivityIntent` can background-launch the app, so
        // `perform()` may run before `onLaunch()` ever does. `pendingResume`
        // would then be nil purely because nothing has read the disk yet,
        // `canAutoStart` would read true, and this would arm a brand-new
        // session whose checkpoint writes overwrite an unrecovered workout.
        // Consult the store, not just the in-memory flag.
        if pendingResume == nil, recorder.state == .idle {
            pendingResume = checkpoints.load()
        }
        // Auto-detected walks are silent even if a voice or system invocation
        // reaches this entry point while one is active.
        guard !recorder.autoStarted else { return .silent }
        guard canAutoStart else { return .alreadyInProgress }
        recorder.start(
            activity: .run,
            armed: true,
            announcesArmedStartOnMovement: announcesStartOnMovement
        )
        presentActiveSessionIfNeeded()
        return .started
    }

    /// A Lock Screen `StartRunIntent` can arm and run a session in a process the
    /// user never saw. When they do open the app, it must land on the live run —
    /// same session, same counters as the Live Activity — not on the Today tab.
    /// Auto-detected walks are excluded: v1.5 chose full silence for those, and
    /// popping a full-screen cover would be the loudest possible violation.
    private func presentActiveSessionIfNeeded() {
        guard recorder.state != .idle, !recorder.autoStarted else { return }
        // `RootTabView` hosts the record cover and the celebration sheet on the
        // same view; asking for both at once drops one of them. The celebration
        // is the older, already-durable event and the one the user has not
        // acknowledged yet, so it wins — `clearPendingCelebration()` re-runs
        // this the moment it is dismissed, and the live run is still there.
        guard pendingCelebration == nil else { return }
        showRecordSheet = true
    }

    /// What a Lock Screen control tap found when it arrived.
    private enum IntentSession: Equatable {
        /// A real in-memory session — act on it directly, as before.
        case existing
        /// Nothing was in memory but a checkpoint was, so the session has been
        /// rehydrated. Carries the checkpoint's `savedAt` as the end-of-activity
        /// fallback for a checkpoint that holds no route points.
        case adopted(endedAt: Date)
        /// Nothing to act on. Any stranded Live Activity has been ended.
        case unavailable
    }

    /// CRITICAL 2 fix. ActivityKit activities outlive the app process, so the
    /// Lock Screen can be showing a live Live Activity with working-looking
    /// Pause and Finish buttons while the app has been killed and relaunched
    /// into a fresh idle recorder. Loading `pendingResume` does not rehydrate
    /// the recorder, so both intents used to hit their no-op guards: the user
    /// tapped Finish on a real-looking run and nothing happened, forever.
    ///
    /// The fix rehydrates rather than special-casing the intents, because that
    /// makes the buttons genuinely work instead of merely failing louder: after
    /// `start(resumeFrom:)` the recorder holds the real session, Pause pauses
    /// it, Resume resumes recording it (a real recovery, without unlocking),
    /// and Finish takes the ordinary, already-tested finish path. It also reuses
    /// the Live Activity mechanism Task 8 built for exactly this case —
    /// `begin()` matches the surviving activity by `startedAt`, which the
    /// checkpoint restores, and adopts it instead of stranding it or stacking a
    /// second one beside it.
    ///
    /// The checkpoint is read from disk rather than from `pendingResume`: a
    /// `LiveActivityIntent` can background-launch the app, and there is no
    /// guarantee `onLaunch()` has run before `perform()` does.
    ///
    /// When no session can be recovered at all — no checkpoint, or a checkpoint
    /// for an activity that never presents a Live Activity — there is nothing
    /// to control, so the surviving activity is a pure orphan. Phase 3's
    /// `endStrandedLiveActivity()` is the existing seam for that; the run's own
    /// data (if any) is left untouched on disk.
    private func resolveIntentSession() -> IntentSession {
        guard recorder.state == .idle else { return .existing }
        guard let checkpoint = pendingResume ?? checkpoints.load(),
              checkpoint.activity == .run else {
            recorder.endStrandedLiveActivity()
            return .unavailable
        }
        // The recorder now owns this session, so the resume prompt must not
        // also claim it.
        pendingResume = nil
        recorder.start(activity: checkpoint.activity, resumeFrom: checkpoint)
        return .adopted(endedAt: checkpoint.savedAt)
    }

    /// Entry point for the Lock Screen / Control Center `TogglePauseIntent`.
    /// Routes through the recorder's own guarded `pauseManually()` /
    /// `resumeManually()` rather than reimplementing the transition: those
    /// carry the hard-won guards against double-announcing while already
    /// auto-paused and against pausing an armed (not-yet-moving) session.
    /// While armed there is nothing to toggle — an armed session has no
    /// motion yet, so "pause" is meaningless and `pauseManually()` already
    /// refuses to run; this guard just makes that explicit at the call site.
    func togglePauseFromIntent() {
        guard resolveIntentSession() != .unavailable else { return }
        // IMPORTANT 7: the widget only renders these controls on manual-run
        // Live Activities, but repository code cannot prove the system never
        // invokes an intent outside the rendered button. Make the auto-walk
        // silence guarantee by construction at the entry point, matching the
        // guards already on every other announcement site.
        guard recorder.activity == .run, !recorder.autoStarted else { return }
        guard !recorder.isArmed else { return }
        // Both paused states must resume here. `liveActivityStatus` renders them
        // identically ("Resume ▶"), so treating only `.manuallyPaused` as paused
        // made the button do the opposite of its label on an auto-paused run — and
        // left it in a state that no longer resumes on movement.
        if recorder.state == .manuallyPaused || recorder.state == .autoPaused {
            recorder.resumeManually()
        } else {
            recorder.pauseManually()
        }
    }

    /// Siri's explicit Pause command. Unlike `togglePauseFromIntent()`, this
    /// can never resume a run that is already paused. It still delegates the
    /// transition to `pauseManually()` so the armed and auto-pause guards, the
    /// checkpoint ordering, and Live Activity update remain centralized.
    @discardableResult
    func pauseRunFromIntent(announcing: Bool = true) -> PauseRunVoiceOutcome {
        guard resolveIntentSession() != .unavailable else { return .noRun }
        // IMPORTANT 7 — see `togglePauseFromIntent()`.
        guard !recorder.autoStarted else { return .silent }
        guard recorder.activity == .run else { return .noRun }
        guard !recorder.isArmed else { return .ready }
        guard recorder.state != .manuallyPaused else { return .alreadyPaused }
        recorder.pauseManually(announcing: announcing)
        return recorder.state == .manuallyPaused ? .paused : .alreadyPaused
    }

    /// Siri's explicit Resume command. Saying "resume" while recording never calls
    /// the toggle and therefore can never pause the run. It resumes an auto-paused
    /// run too: "resume" is unambiguous about what the user wants, and leaving the
    /// detector to notice movement on its own is not what they asked for — the same
    /// reasoning that fixed `togglePauseFromIntent()`.
    @discardableResult
    func resumeRunFromIntent(announcing: Bool = true) -> ResumeRunVoiceOutcome {
        guard resolveIntentSession() != .unavailable else { return .noRun }
        // IMPORTANT 7 — see `togglePauseFromIntent()`.
        guard !recorder.autoStarted else { return .silent }
        guard recorder.activity == .run else { return .noRun }
        guard !recorder.isArmed else { return .ready }
        switch recorder.state {
        case .manuallyPaused, .autoPaused:
            recorder.resumeManually(announcing: announcing)
            return .resumed
        case .recording:
            return .alreadyRunning
        case .idle:
            return .noRun
        }
    }

    /// Siri status uses the same crash-recovery path as the control intents, so
    /// it can report a run whose process died while its checkpoint and Live
    /// Activity survived. Armed and paused sessions are deliberately valid.
    func runStatusFromIntent() -> RunStatusVoiceOutcome {
        guard resolveIntentSession() != .unavailable else { return .noRun }
        // IMPORTANT 7 — status is a user-facing surface too.
        guard !recorder.autoStarted else { return .silent }
        guard recorder.activity == .run else { return .noRun }
        let phase: RunStatusSnapshot.Phase
        if recorder.isArmed {
            phase = .ready
        } else {
            phase = switch recorder.state {
            case .recording: .recording
            case .autoPaused, .manuallyPaused: .paused
            case .idle: .recording
            }
        }
        return .status(
            RunStatusSnapshot(
                phase: phase,
                distanceMeters: recorder.distanceMeters,
                movingSeconds: recorder.movingSeconds,
                paceSecondsPerKm: recorder.paceSecondsPerKm
            )
        )
    }

    /// Entry point for the Lock Screen / Control Center `FinishRunIntent`.
    /// Ends the session at the last real moving timestamp (not "now" — the
    /// Lock Screen tap can land seconds after the user actually stopped),
    /// saves it through the same path as every other save, persists it as
    /// the pending celebration for Task 13 to surface on next open, and
    /// closes out the recorder/Live Activity via `completeSave()`.
    ///
    /// `completeSave()` calls `announceSaved()` internally on the default
    /// Lock Screen path — do not announce separately here, or "Run saved"
    /// speaks twice. The Siri-only wrapper passes `announcingSaved: false`
    /// because its `ProvidesDialog` result owns that invocation's speech.
    ///
    /// CRITICAL 3: the ordering below is chosen so that at every instant the run
    /// is recoverable from at least one durable record. `finish()` leaves a
    /// checkpoint on disk; the celebration is written BEFORE the long save, so
    /// there is no window in which the checkpoint is already gone and the
    /// celebration is not yet there. The checkpoint is destroyed last, and only
    /// once the durable local copy is confirmed.
    ///
    /// CRITICAL 5: `isLocallyDurable` — not "no HealthKit error" — gates both
    /// irreversible acts (clearing the checkpoint, speaking "Run saved"). A
    /// HealthKit-only failure still announces, deliberately: the local store is
    /// the durable copy, so the run really is safe.
    @discardableResult
    func finishRunFromIntent(
        announcingSaved: Bool = true
    ) async -> FinishRunVoiceOutcome {
        let session = resolveIntentSession()
        guard session != .unavailable else { return .noRun }
        // IMPORTANT 7 — see `togglePauseFromIntent()`.
        guard !recorder.autoStarted else { return .silent }
        guard recorder.activity == .run else { return .noRun }
        // A checkpoint with no route points has no last-moving timestamp; its
        // `savedAt` is the closest honest end, and far better than "now" (which
        // would bake however long the process was dead into the workout).
        let fallbackEnd: Date? = if case .adopted(let endedAt) = session { endedAt } else { nil }
        guard let workout = recorder.finish(endingAt: recorder.lastMovingAt ?? fallbackEnd) else {
            return .notStarted
        }
        // Durable before the await, so a kill during the save leaves BOTH the
        // checkpoint and the celebration behind rather than neither.
        var celebrationPersisted = true
        do {
            try pendingCelebrations.save(workout)
            UserDefaults.standard.removeObject(forKey: Self.acknowledgedCelebrationKey)
        } catch {
            celebrationPersisted = false
        }
        let outcome = await sync.saveRecorded(workout)
        guard outcome.isLocallyDurable else {
            // The run exists nowhere but the checkpoint. Keep it, drop the
            // celebration file (it would claim a save that never happened), and
            // stay silent — a missing cue is recoverable, a lost run is not.
            // The Live Activity is deliberately left showing its `.finished`
            // state: its Finish button now routes back through
            // `resolveIntentSession()` and retries this whole path.
            try? pendingCelebrations.clear()
            pendingResume = checkpoints.load()
            return .saveFailed
        }
        // IMPORTANT 6: if the celebration could not be made durable, keep the
        // recovery checkpoint rather than destroying the only other record of
        // the run. The cost is a resume prompt for an already-saved run, and
        // "Save as-is" now upserts under the same stable id rather than
        // duplicating it (see `SyncCoordinator.recordedWorkoutID`).
        if celebrationPersisted {
            checkpoints.clear()
        }
        pendingCelebration = workout
        recorder.completeSave(announcing: announcingSaved)
        return .saved
    }

    /// Called once Task 13's presentation has consumed `pendingCelebration`.
    ///
    /// IMPORTANT 6: a failed delete used to be swallowed while the in-memory
    /// state was cleared regardless, so an acknowledged celebration reappeared
    /// on a later launch. `PendingCelebrationStore.clear()` now falls back to
    /// truncating the file; if even that fails, the acknowledgement is recorded
    /// in UserDefaults — a different storage mechanism, so it can survive
    /// whatever is wrong with the file — and the load path honours it.
    func clearPendingCelebration() {
        let start = pendingCelebration?.start
        do {
            try pendingCelebrations.clear()
            UserDefaults.standard.removeObject(forKey: Self.acknowledgedCelebrationKey)
        } catch {
            if let start {
                UserDefaults.standard.set(start.timeIntervalSince1970,
                                          forKey: Self.acknowledgedCelebrationKey)
            }
        }
        pendingCelebration = nil
        // The celebration was blocking the live-run cover (see
        // `presentActiveSessionIfNeeded()`); now that it is gone, a session
        // still running underneath it gets its screen.
        presentActiveSessionIfNeeded()
    }

    /// Reads the pending celebration, skipping one the user has already
    /// dismissed but whose file could not be deleted (IMPORTANT 6).
    private func loadPendingCelebration() -> RecordedWorkout? {
        guard let workout = pendingCelebrations.load() else { return nil }
        guard let acknowledged = UserDefaults.standard
            .object(forKey: Self.acknowledgedCelebrationKey) as? Double,
              abs(workout.start.timeIntervalSince1970 - acknowledged) < 0.001 else {
            // IMPORTANT 5: the celebration is written BEFORE the local save
            // completes (CRITICAL 3's ordering, which closes a worse window and
            // must not be undone). A kill in that gap leaves a celebration file
            // whose durable row may never have been written — presenting it
            // would assert `isAlreadySaved: true` to the user when it might not
            // be true. The checkpoint is the tell: it is cleared only once the
            // durable copy is confirmed, so as long as one survives for this
            // same session, the celebration is not yet trustworthy. Defer to
            // the resume prompt instead — `saveCheckpointedWorkout()` restores
            // this exact celebration (IMPORTANT 4) once the run is genuinely
            // durable.
            if let checkpoint = checkpoints.load(),
               checkpoint.activity == workout.type, checkpoint.startedAt == workout.start {
                return nil
            }
            return workout
        }
        try? pendingCelebrations.clear()   // opportunistic retry
        return nil
    }

    /// Opt-in so tests can build an AppModel without a motion provider. The
    /// coordinator holds a weak-ish view of the app through closures rather than a
    /// back-reference, keeping the dependency one-way.
    func enableAutoWalk(motion: MotionActivityProviding) {
        autoWalk = AutoWalkCoordinator(
            motion: motion, recorder: recorder, health: health, checkpoints: checkpoints,
            canAutoStart: { [weak self] in
                self?.canAutoStart == true
            },
            // CRITICAL 5, silent path: the coordinator clears the checkpoint
            // after a save, so it has to learn whether the durable write landed.
            // Reporting `false` keeps the walk's recovery copy on disk. Nothing
            // is announced either way — auto-recorded walks stay silent.
            save: { [weak self] workout in
                guard let self else { return false }
                return await self.sync.saveRecorded(workout).isLocallyDurable
            })
    }

    static func live() -> AppModel {
        let store: DataStore
        var storeFailure: String?
        do {
            store = try DataStore()
        } catch {
            storeFailure = error.localizedDescription
            do {
                store = try DataStore(inMemory: true)
            } catch {
                fatalError("Cannot create even an in-memory store: \(error)")
            }
        }
        let checkpoints = CheckpointStore()
        let model = AppModel(store: store,
                             health: HealthStore(),
                             recorder: WorkoutRecorder(
                                 provider: SystemLocationProvider(),
                                 checkpoints: checkpoints,
                                 announcer: RunAnnouncer(),
                                 liveActivity: LiveActivityController(),
                                 // Its own provider instance, not the auto-walk
                                 // one: `startActivityUpdates` replaces the
                                 // handler rather than adding one, so sharing
                                 // would silently unsubscribe whichever wired up
                                 // first.
                                 motion: SystemMotionActivityProvider(),
                                 makeTrace: { startedAt, activity in
                                     SessionTrace(startedAt: startedAt,
                                                  activity: String(describing: activity))
                                 }
                             ),
                             checkpoints: checkpoints)
        model.storeFailureMessage = storeFailure
        model.enableAutoWalk(motion: SystemMotionActivityProvider())
        return model
    }

    func onLaunch() async {
        // CRITICAL 1: load the checkpoint (and any pending celebration) FIRST —
        // synchronously, before a single `await`. Both are cheap local file
        // reads. A pending resume owns the recorder, and `canAutoStart` reads
        // that flag: for as long as `pendingResume` is nil, a cold
        // `StartRunIntent` can arm a brand-new session that then writes through
        // the same `CheckpointStore` and overwrites the unrecovered workout. The
        // comment below this used to claim "load the checkpoint first" while
        // sitting after four awaits; now the code matches it.
        pendingResume = checkpoints.load()
        if pendingCelebration == nil {
            pendingCelebration = loadPendingCelebration()
        }
        presentActiveSessionIfNeeded()
        if await health.shouldRequestAuthorization() {
            try? await health.requestAuthorization()
        }
        await autoWalk?.requestAuthorization()
        await profile.refreshFromHealth()
        health.startObservingSteps { [weak self] in
            Task { @MainActor [weak self] in
                await self?.sync.syncNow()
            }
        }
        // Day rollover while the app stays open: finalize yesterday, reset Today,
        // recompute the streak — without waiting for a foreground/observer event.
        if dayChangeObserver == nil {
            dayChangeObserver = NotificationCenter.default.addObserver(
                forName: .NSCalendarDayChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.sync.syncNow()
                }
            }
        }
        await autoWalk?.onForeground()
        await sync.syncNow()
        if !UserDefaults.standard.bool(forKey: Self.profilePromptKey) {
            showProfilePrompt = true
            UserDefaults.standard.set(true, forKey: Self.profilePromptKey)
        }
    }

    deinit {
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
        }
    }

    func onForeground() async {
        // CRITICAL 1, same ordering hazard as `onLaunch()`: the local reads that
        // decide who owns the recorder go before any `await`. `pendingResume` is
        // re-read here too — this process may have been background-launched by a
        // Lock Screen intent long before the user brought the app forward, and a
        // checkpoint could have appeared since launch.
        if pendingResume == nil, recorder.state == .idle {
            pendingResume = checkpoints.load()
        }
        if pendingCelebration == nil {
            pendingCelebration = loadPendingCelebration()
        }
        presentActiveSessionIfNeeded()
        await profile.refreshFromHealth()
        await autoWalk?.onForeground()
        await sync.syncNow()
    }

    /// "Save as-is" from the crash-resume prompt: credit the checkpointed progress
    /// without resuming the session — the workout is never lost.
    ///
    /// CRITICAL 3 fix: this never touches `recorder` otherwise — the workout
    /// is built straight from the on-disk checkpoint, not from resuming an
    /// in-memory session — so orphan reconciliation (which lives only inside
    /// `LiveActivityController.begin()`) never runs for this path. A Live
    /// Activity that survived a pre-crash process would otherwise stay on
    /// the lock screen forever, showing stale numbers for a run that is now
    /// saved. End it explicitly.
    func saveCheckpointedWorkout() async {
        guard let checkpoint = pendingResume else { return }
        // "Save as-is" on a checkpoint that never covered any distance would
        // write exactly the 0.00 km row `WorkoutRecorder.finish()` now refuses
        // to produce. There is nothing to credit, so treat it as Discard.
        guard checkpoint.distanceMeters > 0 else {
            discardPendingResume()
            return
        }
        let workout = RecordedWorkout(type: checkpoint.activity,
                                      start: checkpoint.startedAt,
                                      end: checkpoint.savedAt,
                                      movingSeconds: checkpoint.movingSeconds,
                                      distanceMeters: checkpoint.distanceMeters,
                                      route: checkpoint.route,
                                      splitSeconds: checkpoint.splitSeconds)
        let outcome = await sync.saveRecorded(workout)
        recorder.endStrandedLiveActivity()
        // CRITICAL 5: the checkpoint is this run's only copy until the local
        // write lands. If it did not, keep it and leave the prompt up.
        guard outcome.isLocallyDurable else { return }
        checkpoints.clear()
        pendingResume = nil
        // IMPORTANT 4: a prior `finishRunFromIntent()` may have durably saved
        // this exact run but failed to persist its celebration file — the
        // checkpoint was kept specifically so this moment could still happen.
        // Without this, the run is safe but the user is never told: the
        // in-memory celebration from that earlier attempt does not survive
        // the process death that made this recovery necessary in the first
        // place. `try?`: a second failure to persist just means no file to
        // reload on a later relaunch — the in-memory celebration still shows
        // right now, same tolerance as IMPORTANT 6.
        UserDefaults.standard.removeObject(forKey: Self.acknowledgedCelebrationKey)
        try? pendingCelebrations.save(workout)
        pendingCelebration = workout
    }

    /// "Discard" from the crash-resume prompt (`RootTabView`'s alert). Same
    /// reasoning as `saveCheckpointedWorkout()` above: this never resumes
    /// the session, so it never reaches `LiveActivityController.begin()`'s
    /// orphan reconciliation — a pre-crash Live Activity would otherwise
    /// strand on the lock screen showing a run that was just thrown away.
    func discardPendingResume() {
        recorder.endStrandedLiveActivity()
        checkpoints.clear()
        pendingResume = nil
    }
}
