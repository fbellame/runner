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
    /// Single source for the allowed daily-goal bounds — the Settings stepper,
    /// the didSet clamp, and storedGoal() must never disagree.
    static let goalRange = 50...500

    let store: DataStore
    let health: HealthStoring
    let sync: SyncCoordinator
    let recorder: WorkoutRecorder
    let checkpoints: CheckpointStore

    var pendingResume: SessionCheckpoint?
    var showRecordSheet = false
    var selectedTab: AppTab = .today
    /// Set when the persistent store failed to open and the app is running on an
    /// in-memory fallback: everything recorded now is lost on relaunch, so the UI
    /// must say so instead of looking healthy.
    var storeFailureMessage: String?

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

    static func storedGoal() -> Int {
        let raw = UserDefaults.standard.object(forKey: goalKey) as? Int ?? 100
        return min(max(raw, goalRange.lowerBound), goalRange.upperBound)
    }

    init(store: DataStore, health: HealthStoring, recorder: WorkoutRecorder, checkpoints: CheckpointStore) {
        self.store = store
        self.health = health
        self.recorder = recorder
        self.checkpoints = checkpoints
        self.dailyGoal = Self.storedGoal()
        self.sync = SyncCoordinator(health: health, store: store, currentGoal: { Self.storedGoal() })
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
        return model
    }

    func onLaunch() async {
        if await health.shouldRequestAuthorization() {
            try? await health.requestAuthorization()
        }
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
        pendingResume = checkpoints.load()
        await sync.syncNow()
    }

    deinit {
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
        }
    }

    func onForeground() async {
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
