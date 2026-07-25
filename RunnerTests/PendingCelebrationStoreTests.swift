import Testing
import Foundation
@testable import Runner

struct PendingCelebrationStoreTests {
    private func makeStore() -> (PendingCelebrationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-celebration-\(UUID().uuidString)")
        return (PendingCelebrationStore(directory: directory), directory)
    }

    private var workout: RecordedWorkout {
        RecordedWorkout(
            type: .run,
            start: Date(timeIntervalSince1970: 1_750_000_000),
            end: Date(timeIntervalSince1970: 1_750_000_600),
            movingSeconds: 600,
            distanceMeters: 2_500,
            route: [],
            splitSeconds: [240, 245]
        )
    }

    @Test func roundTripsAndClears() throws {
        let (store, _) = makeStore()
        try store.save(workout)
        #expect(store.load() == workout)
        try store.clear()
        #expect(store.load() == nil)
    }

    /// IMPORTANT 6: `clear()` is called on paths that may have nothing to
    /// delete (a celebration dismissed twice, or one whose file never landed).
    /// That is not an error and must not throw at the call site.
    @Test func clearingWhenNothingIsStoredIsNotAnError() throws {
        let (store, _) = makeStore()
        try store.clear()
        #expect(store.load() == nil)
    }

    /// IMPORTANT 6: a truncated file is the fallback when deletion fails. It
    /// must read as "nothing pending" rather than resurrecting a celebration.
    @Test func truncatedFileLoadsAsNil() throws {
        let (store, directory) = makeStore()
        try store.save(workout)
        try Data().write(to: directory.appendingPathComponent("pending-celebration.json"))
        #expect(store.load() == nil)
    }

    @Test func corruptFileLoadsAsNil() throws {
        let (store, directory) = makeStore()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("pending-celebration.json")
        )
        #expect(store.load() == nil)
    }
}
