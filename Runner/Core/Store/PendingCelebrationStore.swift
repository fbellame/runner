import Foundation

struct PendingCelebrationStore: Sendable {
    let directory: URL
    private var fileURL: URL {
        directory.appendingPathComponent("pending-celebration.json")
    }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = base.appendingPathComponent(
                "Runner",
                isDirectory: true
            )
        }
    }

    func save(_ workout: RecordedWorkout) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(workout).write(to: fileURL, options: .atomic)
    }

    func load() -> RecordedWorkout? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(RecordedWorkout.self, from: data)
    }

    /// IMPORTANT 6 fix: this used to be `try?`-silent. A failed delete leaves
    /// an already-acknowledged celebration on disk, so it reappears on a later
    /// launch as if the run had just finished. Deletion is not the only way to
    /// make `load()` return nil, so fall back to truncating the file — a
    /// zero-byte file fails to decode and reads as "nothing pending" — and only
    /// throw when even that is impossible, so the caller can compensate.
    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            try Data().write(to: fileURL, options: .atomic)
        }
    }
}
