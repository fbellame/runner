import Foundation

/// Pure state machine for `LiveActivityController`'s deferred-request race
/// guard (Task 8, third fix wave). ActivityKit-free by design (see
/// `LiveActivityOrphanSelector.swift` for why that separation matters) so it
/// is directly unit-testable without ActivityKit or the simulator's
/// `areActivitiesEnabled` gate, which otherwise hides this logic from every
/// test that has to go through `begin()` itself.
///
/// `LiveActivityController.begin()`'s stray-clearing branch must end every
/// non-matching stray BEFORE calling `Activity.request` (ActivityKit
/// enforces a limit on concurrent activities, so requesting while strays
/// are still live risks a silent rejection). That means `begin()` can now
/// return before `activity` is set — a window during which two races would,
/// if left unguarded, manufacture the exact class of orphan this task has
/// spent three fix waves eliminating:
///
///  - Re-entrancy: a second `begin()` arriving while a request is already
///    in flight must not fire a second `Activity.request`.
///  - `end()`/`discard()` racing the deferred request: if the run finishes
///    before the deferred request lands, the request must not be allowed to
///    land and create an activity nobody will ever end.
///
/// A monotonically increasing generation counter closes both. `start()` is
/// called once per deferred attempt and hands back a token identifying it;
/// `isInFlight` is the guard `begin()` uses to refuse a second `start()`;
/// `invalidate()` is called by `end()`/`discard()` to retire whatever
/// attempt is currently in flight; `shouldProceed(_:)` is called by the
/// deferred task immediately before it would call `Activity.request` and
/// returns `true` at most once per `start()` call — only if nothing
/// invalidated (or superseded, via a newer `start()`) the token it holds.
struct LiveActivityRequestGate: Equatable {
    private(set) var generation = 0
    private(set) var isInFlight = false

    /// Begins tracking a new deferred request attempt. Returns the token
    /// that attempt must present to `shouldProceed(_:)` later. Marks the
    /// gate in-flight so `isInFlight` reflects the new attempt immediately
    /// — including superseding whatever attempt (if any) was in flight
    /// before, since its now-stale token can never match this call's
    /// `generation` again.
    mutating func start() -> Int {
        generation += 1
        isInFlight = true
        return generation
    }

    /// Retires whatever attempt is currently in flight, if any. Safe to
    /// call when nothing is in flight (e.g. `end()` running against an
    /// activity that was requested synchronously, with no deferred attempt
    /// involved at all).
    mutating func invalidate() {
        isInFlight = false
    }

    /// Returns `true` exactly once for a given token — the one call that
    /// should actually go on to request the activity and commit
    /// bookkeeping. Every other call (a stale token, or the same token
    /// asked twice) returns `false`. Consumes the in-flight state on a
    /// successful check, so a second caller holding the same token cannot
    /// also proceed.
    mutating func shouldProceed(_ token: Int) -> Bool {
        guard isInFlight, generation == token else { return false }
        isInFlight = false
        return true
    }
}
