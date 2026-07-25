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

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
