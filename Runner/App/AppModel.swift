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

    let store: DataStore
    let health: HealthStoring
    let sync: SyncCoordinator
    let recorder: WorkoutRecorder
    let checkpoints: CheckpointStore

    var pendingResume: SessionCheckpoint?
    var showRecordSheet = false
    var selectedTab: AppTab = .today

    var dailyGoal: Int {
        didSet {
            let clamped = min(max(dailyGoal, 50), 500)
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
        return min(max(raw, 50), 500)
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
        do {
            store = try DataStore()
        } catch {
            store = try! DataStore(inMemory: true)
        }
        let checkpoints = CheckpointStore()
        return AppModel(store: store,
                        health: HealthStore(),
                        recorder: WorkoutRecorder(provider: SystemLocationProvider(),
                                                  checkpoints: checkpoints),
                        checkpoints: checkpoints)
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
        pendingResume = checkpoints.load()
        await sync.syncNow()
    }

    func onForeground() async {
        await sync.syncNow()
    }
}
