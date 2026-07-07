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

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
