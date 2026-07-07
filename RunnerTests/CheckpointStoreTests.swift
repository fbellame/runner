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

    @Test func routePointArrayCodableRoundTrip() throws {
        let points = [RoutePoint(lat: 1, lon: 2, t: .init(timeIntervalSince1970: 3), afterGap: true)]
        let data = try points.encoded()
        #expect([RoutePoint].decode(data) == points)
        #expect([RoutePoint].decode(Data("junk".utf8)) == [])
    }
}
