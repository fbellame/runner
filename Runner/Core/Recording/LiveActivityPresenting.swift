import Foundation

/// Presents run state on the lock screen / Dynamic Island. Deliberately
/// framework-agnostic (no `import ActivityKit`) so it stays testable without
/// loading ActivityKit and so `AutoWalkCoordinator` can keep depending on a
/// silent implementation without ever touching a real Live Activity.
@MainActor
protocol LiveActivityPresenting: Sendable {
    func begin(_ snapshot: RunActivitySnapshot)
    func update(_ snapshot: RunActivitySnapshot)
    func end(_ snapshot: RunActivitySnapshot)

    /// Ends every Live Activity this presenter's underlying framework
    /// currently has on the lock screen — including ones that outlived a
    /// prior, now-dead process, which this presenter's own in-memory state
    /// (e.g. `LiveActivityController.activity`) has no record of.
    ///
    /// Orphan reconciliation normally happens inside `begin()`, but two
    /// crash-recovery exits — `AppModel.saveCheckpointedWorkout()` ("Save
    /// as-is") and the Discard button on the resume prompt — never call
    /// `begin()` at all, since they don't start a new session. Without this,
    /// a Live Activity from a session that crashed mid-run would stay on the
    /// lock screen indefinitely, showing stale numbers for a run that is
    /// already saved or discarded, until the user happened to start another
    /// run. Safe to call when nothing exists.
    func endAllSurvivingActivities()
}

/// Does nothing. Used by `AutoWalkCoordinator` and in tests — auto-recorded
/// walks must never surface a Live Activity.
@MainActor
struct SilentLiveActivityPresenter: LiveActivityPresenting {
    func begin(_ snapshot: RunActivitySnapshot) {}
    func update(_ snapshot: RunActivitySnapshot) {}
    func end(_ snapshot: RunActivitySnapshot) {}
    func endAllSurvivingActivities() {}
}

/// Decides whether a new snapshot warrants pushing an ActivityKit update.
/// ActivityKit enforces an update budget, so GPS-rate updates would get the
/// activity throttled or killed by the system — this policy is what protects
/// that budget: status/warning changes are always urgent, but plain stat
/// deltas (moving time, distance, pace) are coalesced to at most once every
/// `minimumInterval` seconds.
enum RunActivityUpdatePolicy {
    static let minimumInterval: TimeInterval = 5

    static func shouldUpdate(previous: RunActivitySnapshot?,
                             next: RunActivitySnapshot,
                             lastUpdateAt: Date?,
                             now: Date) -> Bool {
        guard let previous, let lastUpdateAt else { return true }
        if previous.status != next.status ||
            previous.reducedAccuracy != next.reducedAccuracy ||
            previous.message != next.message {
            return true
        }
        return now.timeIntervalSince(lastUpdateAt) >= minimumInterval
    }
}
