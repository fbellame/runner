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
}

/// Does nothing. Used by `AutoWalkCoordinator` and in tests — auto-recorded
/// walks must never surface a Live Activity.
@MainActor
struct SilentLiveActivityPresenter: LiveActivityPresenting {
    func begin(_ snapshot: RunActivitySnapshot) {}
    func update(_ snapshot: RunActivitySnapshot) {}
    func end(_ snapshot: RunActivitySnapshot) {}
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
