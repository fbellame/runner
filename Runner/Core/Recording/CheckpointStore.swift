import Foundation

struct SessionCheckpoint: Codable, Equatable {
    let activity: ActivityType
    let startedAt: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let route: [RoutePoint]
    let splitSeconds: [Double]
    let savedAt: Date
    /// True when the session was manually paused at the moment this checkpoint
    /// was written. CRITICAL 2 fix: without this, rehydrating a checkpoint
    /// (`WorkoutRecorder.start(resumeFrom:)`) always restored `.recording`,
    /// even for a run that was paused when the process died — so the Live
    /// Activity kept showing a "Resume" button whose first tap actually paused
    /// the (already-restarted-as-recording) session.
    ///
    /// MIGRATION: checkpoints written by 1.10 (15) and earlier — real files on
    /// the user's phone right now — have no such key on disk. `init(from:)`
    /// below defaults a missing key to `false`, matching that build's actual
    /// behavior (always resumed as recording), rather than letting a
    /// perfectly good, still-live checkpoint fail to decode and be silently
    /// discarded as "nothing to recover."
    let isPaused: Bool

    init(activity: ActivityType, startedAt: Date, movingSeconds: Double,
         distanceMeters: Double, route: [RoutePoint], splitSeconds: [Double],
         savedAt: Date, isPaused: Bool = false) {
        self.activity = activity
        self.startedAt = startedAt
        self.movingSeconds = movingSeconds
        self.distanceMeters = distanceMeters
        self.route = route
        self.splitSeconds = splitSeconds
        self.savedAt = savedAt
        self.isPaused = isPaused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activity = try container.decode(ActivityType.self, forKey: .activity)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        movingSeconds = try container.decode(Double.self, forKey: .movingSeconds)
        distanceMeters = try container.decode(Double.self, forKey: .distanceMeters)
        route = try container.decode([RoutePoint].self, forKey: .route)
        splitSeconds = try container.decode([Double].self, forKey: .splitSeconds)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
    }
}

struct CheckpointStore {
    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("checkpoint.json") }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("Runner", isDirectory: true)
        }
    }

    func save(_ checkpoint: SessionCheckpoint) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: fileURL, options: .atomic)
    }

    func load() -> SessionCheckpoint? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionCheckpoint.self, from: data)
    }

    /// Same hardening as `PendingCelebrationStore.clear()` (IMPORTANT 6): a
    /// silently-failed delete leaves a checkpoint behind for a run that has
    /// already been saved, which raises a spurious crash-resume prompt. A
    /// truncated file fails to decode, so `load()` still reads as "nothing to
    /// resume". Kept non-throwing — every call site clears a checkpoint whose
    /// workout is already durable elsewhere, and the residual risk is now a
    /// duplicate-looking prompt rather than a lost or duplicated workout (the
    /// stable id in `SyncCoordinator.recordedWorkoutID` makes a re-save of the
    /// same session an upsert, not a second row).
    func clear() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            try? Data().write(to: fileURL, options: .atomic)
        }
    }
}
