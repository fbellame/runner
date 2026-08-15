import Foundation

/// Pure decision logic for `LiveActivityController.begin()`'s orphan-adoption
/// step. ActivityKit-free by design (see `LiveActivityPresenting.swift` for
/// why that separation matters) so it is directly unit-testable without the
/// simulator's `areActivitiesEnabled` gate, which otherwise hides this logic
/// from every test that has to go through `begin()` itself.
///
/// A surviving Live Activity from a previous process (crash/force-quit
/// before `end()` ran) should only be adopted when it belongs to the SAME
/// run that is now starting — otherwise a brand-new run would silently
/// inherit a stale activity's identity. Session identity is represented here
/// as a plain `Date` (see `LiveActivityController` for why `startedAt` is the
/// chosen key) so this type never has to know about `Activity` itself.
enum LiveActivityOrphanSelector {
    /// - `adoptIndex`: index into the input array to adopt and refresh, if any.
    /// - `endIndices`: indices into the input array that must be ended
    ///   (`dismissalPolicy: .immediate`) because they do not belong to the
    ///   run now starting.
    struct Decision: Equatable {
        let adoptIndex: Int?
        let endIndices: [Int]
    }

    /// - Parameters:
    ///   - existingSessionKeys: the session key (e.g. `startedAt`) currently
    ///     shown by each surviving activity, in the order ActivityKit
    ///     returned them.
    ///   - incoming: the session key of the run that is now starting.
    static func decide(existingSessionKeys: [Date], incoming: Date) -> Decision {
        guard let matchIndex = existingSessionKeys.firstIndex(of: incoming) else {
            return Decision(adoptIndex: nil, endIndices: Array(existingSessionKeys.indices))
        }
        let endIndices = existingSessionKeys.indices.filter { $0 != matchIndex }
        return Decision(adoptIndex: matchIndex, endIndices: endIndices)
    }
}
