import Foundation

struct SessionCheckpoint: Codable, Equatable {
    let activity: ActivityType
    let startedAt: Date
    let movingSeconds: Double
    let distanceMeters: Double
    let route: [RoutePoint]
    let splitSeconds: [Double]
    let savedAt: Date
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
