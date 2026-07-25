import Testing
import Foundation
@testable import Runner

struct CheckpointStoreTests {
    private func tempStore() -> CheckpointStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-tests-\(UUID().uuidString)")
        return CheckpointStore(directory: dir)
    }

    private var sample: SessionCheckpoint {
        SessionCheckpoint(activity: .bike,
                          startedAt: Date(timeIntervalSince1970: 1_750_000_000),
                          movingSeconds: 340,
                          distanceMeters: 2_450,
                          route: [RoutePoint(lat: 45.5, lon: -73.6,
                                             t: Date(timeIntervalSince1970: 1_750_000_100),
                                             afterGap: false)],
                          splitSeconds: [301.5, 322.0],
                          savedAt: Date(timeIntervalSince1970: 1_750_000_340))
    }

    @Test func roundTrip() throws {
        let store = tempStore()
        try store.save(sample)
        #expect(store.load() == sample)
    }

    @Test func loadWithoutSaveReturnsNil() {
        #expect(tempStore().load() == nil)
    }

    @Test func clearRemovesCheckpoint() throws {
        let store = tempStore()
        try store.save(sample)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func corruptFileReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-tests-\(UUID().uuidString)")
        let store = CheckpointStore(directory: dir)
        try store.save(sample) // creates directory
        try Data("not json".utf8).write(to: dir.appendingPathComponent("checkpoint.json"))
        #expect(store.load() == nil)
    }

    @Test func roundTripPreservesPausedFlag() throws {
        let store = tempStore()
        let paused = SessionCheckpoint(activity: .run, startedAt: sample.startedAt,
                                       movingSeconds: sample.movingSeconds,
                                       distanceMeters: sample.distanceMeters,
                                       route: sample.route, splitSeconds: sample.splitSeconds,
                                       savedAt: sample.savedAt, isPaused: true)
        try store.save(paused)
        #expect(store.load()?.isPaused == true)
    }

    /// CRITICAL 2 migration regression: real checkpoints written by 1.10 (15)
    /// and earlier have no "isPaused" key on disk at all. Adding a non-optional
    /// field without this handling would make `JSONDecoder` throw on those
    /// files, and `load()` swallows decode errors as "nothing to recover" —
    /// silently discarding a genuine, still-live recovery checkpoint. This
    /// proves an old-format file still decodes, defaulting to `isPaused == false`
    /// (that build's actual behavior: always resume as recording).
    @Test func oldFormatCheckpointWithoutPausedKeyStillDecodes() throws {
        let store = tempStore()
        let data = try JSONEncoder().encode(sample)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["isPaused"] != nil)          // sanity: the new key really is present
        json.removeValue(forKey: "isPaused")      // simulate a pre-upgrade file
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try legacyData.write(to: store.directory.appendingPathComponent("checkpoint.json"))

        let loaded = try #require(store.load())

        #expect(loaded.isPaused == false)
        #expect(loaded.activity == sample.activity)
        #expect(loaded.distanceMeters == sample.distanceMeters)
    }

    @Test func routePointArrayCodableRoundTrip() throws {
        let points = [RoutePoint(lat: 1, lon: 2, t: .init(timeIntervalSince1970: 3), afterGap: true)]
        let data = try points.encoded()
        #expect([RoutePoint].decode(data) == points)
        #expect([RoutePoint].decode(Data("junk".utf8)) == [])
    }
}
