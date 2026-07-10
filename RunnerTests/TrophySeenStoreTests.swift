import Testing
import Foundation
@testable import Runner

struct TrophySeenStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = "TrophySeenStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func badgesAreUnseenByDefault() {
        #expect(!TrophySeenStore(defaults: freshDefaults()).isSeen("distance.run.10"))
    }

    @Test func markedBadgesPersistAcrossStoreInstances() {
        let defaults = freshDefaults()
        TrophySeenStore(defaults: defaults).markSeen(["distance.run.10"])

        #expect(TrophySeenStore(defaults: defaults).isSeen("distance.run.10"))
    }

    @Test func markingSeenIsAdditiveAndIdempotent() {
        let store = TrophySeenStore(defaults: freshDefaults())
        store.markSeen(["distance.run.10", "distance.run.10"])
        store.markSeen(["count.global.10"])

        #expect(store.isSeen("distance.run.10"))
        #expect(store.isSeen("count.global.10"))
    }
}
