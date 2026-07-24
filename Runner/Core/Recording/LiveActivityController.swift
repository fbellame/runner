import Foundation
import ActivityKit

// ActivityKit predates Swift 6 concurrency annotations: `Activity<Attributes>`
// is a plain class with no `Sendable` conformance in this SDK. Rather than
// `@preconcurrency import ActivityKit` — which would exempt the framework's
// ENTIRE surface (including `activityStateUpdates`/`activityUpdates`/
// `pushTokenUpdates`, `AsyncSequence`s that genuinely do cross isolation
// domains and that a future task consuming one in this file would then get
// zero compiler help with) — assert only the one thing that is actually
// true: an `Activity` is safe to hand across the `Task { }` hops below,
// because every ActivityKit call this controller makes on it is itself
// `@MainActor`-safe to originate from and nothing here mutates shared state
// off the main actor.
extension Activity: @retroactive @unchecked Sendable {}

/// The real `LiveActivityPresenting` implementation: owns the single
/// `Activity<RunAttributes>` for the run currently on screen and talks to
/// ActivityKit. Every ActivityKit call that requires `await` is hopped onto
/// its own `Task` so `begin`/`update`/`end` stay synchronous — callers
/// (`WorkoutRecorder`'s hot path) must never suspend.
@MainActor
final class LiveActivityController: LiveActivityPresenting {
    private var activity: Activity<RunAttributes>?
    private var previous: RunActivitySnapshot?
    private var lastUpdateAt: Date?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    func begin(_ snapshot: RunActivitySnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              activity == nil else { return }

        // ActivityKit activities outlive this process. If the app was
        // killed mid-run (jetsam, force-quit, or a crash while the summary
        // sheet was still open), no `end` ever ran — the OS is still
        // showing that (now-stale) Live Activity on the lock screen even
        // though a fresh process's `activity` here is `nil`. Requesting a
        // new one unconditionally would put TWO Live Activities for the
        // same run on the lock screen (one frozen pre-crash, one live), and
        // finishing/saving would only ever end the new one. Adopt an
        // existing activity instead of blindly requesting a new one.
        //
        // Adoption (rather than ending every stray and requesting fresh) is
        // chosen deliberately: ending an activity and immediately requesting
        // a new one is visibly a dismiss-then-reappear on the lock screen
        // the user cannot see happen (phone is zipped away) but WILL see
        // when they eventually look — the entry would appear to have reset.
        // Adopting keeps the existing lock-screen entry in place and simply
        // refreshes its content, which is the more honest continuation of
        // "the run that was already showing here."
        let existing = Activity<RunAttributes>.activities
        if let adopted = existing.first {
            activity = adopted
            // More than one stray can exist after repeated crash/relaunch
            // cycles (each prior `begin()` in a since-dead process could
            // have adopted or requested one). Only the first is kept; any
            // others are dead weight on the lock screen and are ended.
            for stray in existing.dropFirst() {
                Task { await stray.end(nil, dismissalPolicy: .immediate) }
            }
            // The adopted activity's content is whatever it last showed
            // before the crash — push the current snapshot right away so
            // the lock screen stops showing stale pre-crash numbers instead
            // of waiting for the next naturally-throttled `update()` call.
            Task {
                await adopted.update(ActivityContent(
                    state: RunAttributes.ContentState(snapshot: snapshot),
                    staleDate: nil
                ))
            }
            previous = snapshot
            lastUpdateAt = clock()
            return
        }

        let content = ActivityContent(
            state: RunAttributes.ContentState(snapshot: snapshot),
            staleDate: nil
        )
        activity = try? Activity.request(
            attributes: RunAttributes(sessionID: UUID()),
            content: content,
            pushType: nil
        )
        previous = snapshot
        lastUpdateAt = clock()
    }

    func update(_ snapshot: RunActivitySnapshot) {
        let now = clock()
        guard let activity,
              RunActivityUpdatePolicy.shouldUpdate(
                previous: previous,
                next: snapshot,
                lastUpdateAt: lastUpdateAt,
                now: now
              ) else { return }
        previous = snapshot
        lastUpdateAt = now
        Task {
            await activity.update(ActivityContent(
                state: RunAttributes.ContentState(snapshot: snapshot),
                staleDate: nil
            ))
        }
    }

    func end(_ snapshot: RunActivitySnapshot) {
        guard let activity else { return }
        self.activity = nil
        previous = nil
        lastUpdateAt = nil
        Task {
            await activity.end(
                ActivityContent(
                    state: RunAttributes.ContentState(snapshot: snapshot),
                    staleDate: nil
                ),
                dismissalPolicy: .immediate
            )
        }
    }
}
