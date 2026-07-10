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
    /// Single source for the allowed daily-goal bounds — the Settings stepper,
    /// the didSet clamp, and storedGoal() must never disagree.
    static let goalRange = 50...500

    static let weeklyTargetKey = "weeklyGoldTarget"
    /// Allowed weekly consistency target — gold days per week.
    static let weeklyTargetRange = 1...7

    let store: DataStore
    let health: HealthStoring
    let sync: SyncCoordinator
    let recorder: WorkoutRecorder
    let checkpoints: CheckpointStore
    let profile: ProfileStore
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

    var dailyGoal: Int {
        didSet {
            let clamped = min(max(dailyGoal, Self.goalRange.lowerBound), Self.goalRange.upperBound)
            if clamped != dailyGoal {
                dailyGoal = clamped
                return
            }
            UserDefaults.standard.set(dailyGoal, forKey: Self.goalKey)
            Task { await sync.syncNow() }
        }
    }

    var weeklyGoldTarget: Int {
        didSet {
            let clamped = min(max(weeklyGoldTarget, Self.weeklyTargetRange.lowerBound), Self.weeklyTargetRange.upperBound)
            if clamped != weeklyGoldTarget {
                weeklyGoldTarget = clamped
                return
            }
            UserDefaults.standard.set(weeklyGoldTarget, forKey: Self.weeklyTargetKey)
            Task { await sync.syncNow() }
        }
    }

    static func storedGoal() -> Int {
        let raw = UserDefaults.standard.object(forKey: goalKey) as? Int ?? 100
        return min(max(raw, goalRange.lowerBound), goalRange.upperBound)
    }

    static func storedWeeklyTarget() -> Int {
        let raw = UserDefaults.standard.object(forKey: weeklyTargetKey) as? Int ?? 3
        return min(max(raw, weeklyTargetRange.lowerBound), weeklyTargetRange.upperBound)
    }

    init(store: DataStore, health: HealthStoring, recorder: WorkoutRecorder, checkpoints: CheckpointStore) {
        self.store = store
        self.health = health
        self.recorder = recorder
        self.checkpoints = checkpoints
        self.dailyGoal = Self.storedGoal()
        self.weeklyGoldTarget = Self.storedWeeklyTarget()
        let profile = ProfileStore(store: store, health: health)
        self.profile = profile
        self.sync = SyncCoordinator(health: health, store: store,
                                    currentGoal: { Self.storedGoal() },
                                    currentWeeklyTarget: { Self.storedWeeklyTarget() },
                                    metricsProvider: { profile.currentMetrics() })
    }

    /// Opt-in so tests can build an AppModel without a motion provider. The
    /// coordinator holds a weak-ish view of the app through closures rather than a
    /// back-reference, keeping the dependency one-way.
    func enableAutoWalk(motion: MotionActivityProviding) {
        autoWalk = AutoWalkCoordinator(
            motion: motion, recorder: recorder, health: health, checkpoints: checkpoints,
            canAutoStart: { [weak self] in
                guard let self else { return false }
                // The record sheet and an unanswered resume prompt both own the
                // recorder; a manual session must never be hijacked.
                return self.pendingResume == nil && !self.showRecordSheet
            },
            save: { [weak self] workout in
                await self?.sync.saveRecorded(workout)
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
                             recorder: WorkoutRecorder(provider: SystemLocationProvider(),
                                                       checkpoints: checkpoints),
                             checkpoints: checkpoints)
        model.storeFailureMessage = storeFailure
        model.enableAutoWalk(motion: SystemMotionActivityProvider())
        return model
    }

    func onLaunch() async {
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
        // Load the checkpoint first: a pending resume owns the recorder, and the
        // auto-walk guard reads that flag.
        pendingResume = checkpoints.load()
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
        await profile.refreshFromHealth()
        await autoWalk?.onForeground()
        await sync.syncNow()
    }

    /// "Save as-is" from the crash-resume prompt: credit the checkpointed progress
    /// without resuming the session — the workout is never lost.
    func saveCheckpointedWorkout() async {
        guard let checkpoint = pendingResume else { return }
        let workout = RecordedWorkout(type: checkpoint.activity,
                                      start: checkpoint.startedAt,
                                      end: checkpoint.savedAt,
                                      movingSeconds: checkpoint.movingSeconds,
                                      distanceMeters: checkpoint.distanceMeters,
                                      route: checkpoint.route,
                                      splitSeconds: checkpoint.splitSeconds)
        await sync.saveRecorded(workout)
        checkpoints.clear()
        pendingResume = nil
    }
}
