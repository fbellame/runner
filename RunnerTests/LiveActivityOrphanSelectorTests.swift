import Testing
import Foundation
@testable import Runner

/// Covers the Task 8 re-review fix: `LiveActivityController.begin()` must
/// only adopt a surviving Live Activity when it belongs to the SAME run
/// that is now starting (matched by session key, e.g. `startedAt`), not
/// unconditionally adopt whatever ActivityKit happens to return first.
/// `LiveActivityOrphanSelector.decide` is the pure, ActivityKit-free
/// extraction of that decision, so it's testable without the simulator's
/// `areActivitiesEnabled` gate.
struct LiveActivityOrphanSelectorTests {
    private let now = Date()

    @Test func noExistingActivitiesAdoptsNothingAndEndsNothing() {
        let decision = LiveActivityOrphanSelector.decide(existingSessionKeys: [], incoming: now)
        #expect(decision.adoptIndex == nil)
        #expect(decision.endIndices == [])
    }

    @Test func oneMatchingActivityIsAdoptedAndNothingIsEnded() {
        let decision = LiveActivityOrphanSelector.decide(existingSessionKeys: [now], incoming: now)
        #expect(decision.adoptIndex == 0)
        #expect(decision.endIndices == [])
    }

    @Test func oneNonMatchingActivityIsEndedNotAdopted() {
        let stale = now.addingTimeInterval(-3_600)
        let decision = LiveActivityOrphanSelector.decide(existingSessionKeys: [stale], incoming: now)
        #expect(decision.adoptIndex == nil)
        #expect(decision.endIndices == [0])
    }

    @Test func severalActivitiesWhereOneMatchesAdoptsThatOneAndEndsTheRest() {
        let stale1 = now.addingTimeInterval(-3_600)
        let stale2 = now.addingTimeInterval(-7_200)
        let decision = LiveActivityOrphanSelector.decide(
            existingSessionKeys: [stale1, now, stale2],
            incoming: now
        )
        #expect(decision.adoptIndex == 1)
        #expect(decision.endIndices == [0, 2])
    }

    @Test func severalActivitiesWhereNoneMatchAdoptsNothingAndEndsAll() {
        let stale1 = now.addingTimeInterval(-3_600)
        let stale2 = now.addingTimeInterval(-7_200)
        let decision = LiveActivityOrphanSelector.decide(
            existingSessionKeys: [stale1, stale2],
            incoming: now
        )
        #expect(decision.adoptIndex == nil)
        #expect(decision.endIndices == [0, 1])
    }
}
